import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Renders one image/PDF source into a searchable PDF whose pages show the
/// original content with an invisible, selectable OCR text layer on top.
///
/// - An image source becomes a single page, sized from embedded DPI metadata
///   when present, falling back to 72 DPI (1 px = 1 pt). EXIF orientation is
///   baked in so the page renders upright.
/// - A PDF source preserves every original page verbatim — vector content is
///   drawn into the output PDF, not rasterized — so quality and file size are
///   maintained. Each page is still rasterized internally (off to the side) to
///   feed text recognition.
///
/// One input maps to one output; sources are never merged. The text layer is
/// line-level: one invisible text run per recognized observation, positioned
/// from the observation's bounding box.
public enum SearchablePDF {

	/// Render a single source into a searchable PDF and return its bytes.
	///
	/// `ocrAllPages` disables the born-digital skip: every PDF page is OCR'd,
	/// including pages that already draw text. Needed for hybrid pages (a scan
	/// plus a small digital stamp/page number), at the cost of doubling any
	/// existing digital text in copy/search.
	///
	/// `onProgress` is invoked on the calling task as pages complete — first
	/// with `(0, total)` once the page count is known, then `(done, total)`
	/// after each page is written. It never fires from a background render
	/// task, so the closure needs no synchronization.
	///
	/// When **every** page of a PDF already has selectable text (and
	/// `ocrAllPages` is off), the input bytes are returned verbatim: there is
	/// nothing to add, and a rewrite would silently drop annotations — links,
	/// form fields — plus outlines and metadata, which only survive the
	/// pass-through path.
	public static func render(
		source: ImageSource,
		options: OCROptions,
		pdfDpi: Int?,
		password: String? = nil,
		ocrAllPages: Bool = false,
		imageQuality: Double? = nil,
		onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil
	) async throws -> Data {
		try validateImageQuality(imageQuality)
		let producer = try await resolveProducer(source, password: password, imageQuality: imageQuality)

		if case .pdf(let document, _, let originalData) = producer, !ocrAllPages {
			let pageCount = document.numberOfPages
			guard pageCount > 0 else {
				throw MessageError("PDF has no pages: \(source.displayName)")
			}
			var allPagesHaveText = true
			for pageNumber in 1...pageCount {
				guard let page = document.page(at: pageNumber) else {
					throw MessageError("Could not load PDF page \(pageNumber)")
				}
				if !pageHasTextLayer(page) {
					allPagesHaveText = false
					break
				}
			}
			if allPagesHaveText, let original = originalData() {
				onProgress?(0, pageCount)
				onProgress?(pageCount, pageCount)
				return original
			}
		}

		let pdfData = NSMutableData()
		guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
			let context = CGContext(consumer: consumer, mediaBox: nil, nil)
		else {
			throw MessageError("Could not create PDF output context")
		}

		let pagesWritten = try await appendSource(
			producer, displayName: source.displayName, options: options, pdfDpi: pdfDpi,
			ocrAllPages: ocrAllPages, into: context, onProgress: onProgress
		)

		guard pagesWritten > 0 else {
			throw MessageError("No pages were produced")
		}

		context.closePDF()
		return pdfData as Data
	}

	// MARK: - Source resolution

	private enum PageProducer {
		/// A PDF document whose original pages are preserved (vector-safe).
		/// `reopen` yields an independent document instance, letting a page
		/// render on a background task while the main document draws output —
		/// CGPDFDocument is not thread-safe, so the two paths must not share
		/// one. `originalData` yields the untouched input bytes for the
		/// verbatim pass-through when no page needs OCR.
		case pdf(document: CGPDFDocument, reopen: () -> CGPDFDocument?, originalData: () -> Data?)
		/// A single, orientation-corrected (upright) raster image.
		case image(ImagePage)
	}

	private struct ImagePage {
		let image: CGImage
		let mediaBox: CGRect
		let visiblePDFData: Data
		let visiblePDFDocument: CGPDFDocument
		let visiblePDFPage: CGPDFPage
	}

	/// Per-page geometry and OCR decision, computed serially up front on the
	/// main document so the page-ordered output loop never touches the document
	/// concurrently with a background render.
	private struct PagePlan {
		let page: CGPDFPage
		let pageNumber: Int
		let displayBox: CGRect
		let drawingTransform: CGAffineTransform
		let needsOCR: Bool
	}

	/// Carries a non-Sendable CoreGraphics value across a render-task boundary.
	/// The reopened render document and the image it produces are owned by
	/// exactly one render task at a time and are never touched concurrently with
	/// the main document, so the transfer is safe.
	private struct Unchecked<T>: @unchecked Sendable {
		let value: T
	}

	// TODO: The rewrite below drops annotations (links, form fields),
	// outlines, and document metadata — only the verbatim pass-through in
	// `render` preserves them, and that requires *every* page to already have
	// text. A mixed scanned+digital document loses its annotations on all
	// pages. A future improvement could transplant annotations onto the
	// rewritten output via PDFKit (re-add per page after rendering), but
	// that's lossy and risky (field hierarchies, appearance streams).
	private static func appendSource(
		_ producer: PageProducer,
		displayName: String,
		options: OCROptions,
		pdfDpi: Int?,
		ocrAllPages: Bool,
		into context: CGContext,
		onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil
	) async throws -> Int {
		switch producer {
		case .pdf(let document, let reopen, _):
			let pageCount = document.numberOfPages
			guard pageCount > 0 else {
				throw MessageError("PDF has no pages: \(displayName)")
			}

			// Plan every page up front (serial, main document): the displayed
			// geometry — CropBox oriented by /Rotate, with a transform mapping
			// the original vector content into it so crop/rotation are preserved
			// — and whether the page needs OCR. Born-digital pages that already
			// carry selectable text are skipped (adding a layer would duplicate
			// copy/search text) unless `ocrAllPages` overrides the detection
			// for hybrid scan-plus-stamp pages.
			var plans: [PagePlan] = []
			plans.reserveCapacity(pageCount)
			for pageNumber in 1...pageCount {
				guard let page = document.page(at: pageNumber) else {
					throw MessageError("Could not load PDF page \(pageNumber)")
				}
				let cropBox = page.getBoxRect(.cropBox)
				// Widen to Int before abs: abs(Int32.min) traps on a hostile /Rotate.
				let rotated = abs(Int(page.rotationAngle)) % 180 == 90
				let displayBox = CGRect(
					x: 0,
					y: 0,
					width: rotated ? cropBox.height : cropBox.width,
					height: rotated ? cropBox.width : cropBox.height
				)
				plans.append(
					PagePlan(
						page: page,
						pageNumber: pageNumber,
						displayBox: displayBox,
						drawingTransform: page.getDrawingTransform(
							.cropBox, rect: displayBox, rotate: 0, preserveAspectRatio: false
						),
						needsOCR: ocrAllPages || !pageHasTextLayer(page)
					))
			}

			// Rendering is CPU-bound; OCR runs on the serial, ANE-bound Vision
			// executor. Overlap them: while page N is recognized, page N+1's
			// raster already renders on a background task using an independent
			// document instance (the main document is busy drawing finished
			// vector pages into the output). At most one render runs ahead, so
			// peak memory stays at ~one extra raster. If the document can't be
			// reopened, rendering falls back inline on the main document.
			let renderDocument = reopen()
			let fallbackColorSpace = CGColorSpaceCreateDeviceRGB()

			func startRender(planIndex: Int) -> Task<Unchecked<CGImage>, Error>? {
				guard let renderDocument, plans[planIndex].needsOCR else { return nil }
				let document = Unchecked(value: renderDocument)
				let pageNumber = plans[planIndex].pageNumber
				return Task.detached(priority: .userInitiated) {
					Unchecked(
						value: try renderPDFPage(
							document: document.value,
							pageIndex: pageNumber,
							colorSpace: CGColorSpaceCreateDeviceRGB(),
							requestedDpi: pdfDpi
						))
				}
			}

			func nextOCRIndex(after index: Int) -> Int? {
				var i = index + 1
				while i < plans.count {
					if plans[i].needsOCR { return i }
					i += 1
				}
				return nil
			}

			var prefetchIndex = plans.firstIndex { $0.needsOCR }
			var prefetch = prefetchIndex.flatMap { startRender(planIndex: $0) }

			onProgress?(0, pageCount)
			for (index, plan) in plans.enumerated() {
				let ocr: OCRResult
				if plan.needsOCR {
					let raster: CGImage
					if let task = prefetch, prefetchIndex == index {
						raster = try await task.value.value
						// Start the next page's render so it overlaps this OCR.
						prefetchIndex = nextOCRIndex(after: index)
						prefetch = prefetchIndex.flatMap { startRender(planIndex: $0) }
					} else {
						raster = try renderPDFPage(
							document: document,
							pageIndex: plan.pageNumber,
							colorSpace: fallbackColorSpace,
							requestedDpi: pdfDpi
						)
					}
					ocr = try await recognize(raster, options: options)
				} else {
					ocr = OCRResult(text: "", observations: [])
				}

				writePage(mediaBox: plan.displayBox, ocr: ocr, into: context) { context in
					context.concatenate(plan.drawingTransform)
					context.drawPDFPage(plan.page)
				}
				onProgress?(index + 1, pageCount)
			}
			return pageCount

		case .image(let page):
			onProgress?(0, 1)
			let image = page.image
			let mediaBox = page.mediaBox
			let ocr = try await recognize(image, options: options)
			writePage(mediaBox: mediaBox, ocr: ocr, into: context) { context in
				context.concatenate(
					page.visiblePDFPage.getDrawingTransform(
						.cropBox, rect: mediaBox, rotate: 0, preserveAspectRatio: false
					))
				context.drawPDFPage(page.visiblePDFPage)
			}
			onProgress?(1, 1)
			return 1
		}
	}

	private static func resolveProducer(
		_ source: ImageSource,
		password: String?,
		imageQuality: Double?
	) async throws -> PageProducer {
		switch source {
		case .file(let path):
			let url = URL(fileURLWithPath: path)
			guard FileManager.default.fileExists(atPath: url.path) else {
				throw MessageError("No such file: \(path)")
			}
			if isPDFFile(url: url) {
				guard let document = CGPDFDocument(url as CFURL) else {
					throw MessageError("Cannot read PDF: \(path)")
				}
				try unlockPDF(document, password: password, label: path)
				return .pdf(
					document: document,
					reopen: {
						let reopened = CGPDFDocument(url as CFURL)
						reopened.map { unlockReopenedPDF($0, password: password) }
						return reopened
					},
					originalData: { try? Data(contentsOf: url) })
			}
			guard let source = CGImageSourceCreateWithURL(url as CFURL, nil)
			else {
				throw MessageError("Cannot read image: \(path)")
			}
			return .image(try imagePage(from: source, label: path, imageQuality: imageQuality))

		case .url(let urlString):
			guard let remoteURL = URL(string: urlString) else {
				throw MessageError("Invalid URL: \(urlString)")
			}
			let data = try await fetchRemoteData(from: remoteURL, label: urlString)
			return try producer(fromData: data, label: urlString, password: password, imageQuality: imageQuality)

		case .stdin:
			let data = try readAllStandardInput()
			guard !data.isEmpty else {
				throw MessageError("No data received on stdin")
			}
			return try producer(fromData: data, label: "stdin", password: password, imageQuality: imageQuality)
		}
	}

	private static func producer(
		fromData data: Data,
		label: String,
		password: String?,
		imageQuality: Double?
	) throws -> PageProducer {
		if isPDFData(data) {
			guard let provider = CGDataProvider(data: data as CFData),
				let document = CGPDFDocument(provider)
			else {
				throw MessageError("Cannot read PDF from \(label)")
			}
			try unlockPDF(document, password: password, label: label)
			// Reopen from the retained bytes; an independent instance renders
			// pages off the main document without sharing thread-unsafe state.
			return .pdf(
				document: document,
				reopen: {
					let reopened = CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)
					reopened.map { unlockReopenedPDF($0, password: password) }
					return reopened
				},
				originalData: { data })
		}
		guard let source = CGImageSourceCreateWithData(data as CFData, nil)
		else {
			throw MessageError("Cannot read image from \(label)")
		}
		return .image(try imagePage(from: source, label: label, imageQuality: imageQuality))
	}

	private static func validateImageQuality(_ value: Double?) throws {
		guard let value else { return }
		guard value.isFinite, value >= 0, value <= 1 else {
			throw MessageError("--image-quality must be between 0.0 and 1.0")
		}
	}

	private static func imagePage(
		from source: CGImageSource,
		label: String,
		imageQuality: Double?
	) throws -> ImagePage {
		guard let image = uprightImage(from: source) else {
			throw MessageError("Cannot read image from \(label)")
		}
		let visibleImage = imageQuality == nil ? image : flattenOverWhite(image)
		let data = try makeVisibleImagePDF(image: visibleImage, imageQuality: imageQuality)
		guard let provider = CGDataProvider(data: data as CFData),
			let document = CGPDFDocument(provider),
			let page = document.page(at: 1)
		else {
			throw MessageError("Could not create PDF image layer for \(label)")
		}
		return ImagePage(
			image: image,
			mediaBox: imageMediaBox(source: source, image: image),
			visiblePDFData: data,
			visiblePDFDocument: document,
			visiblePDFPage: page
		)
	}

	private static func imageMediaBox(source: CGImageSource, image: CGImage) -> CGRect {
		let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
		let rawWidth = dpiValue(properties?[kCGImagePropertyDPIWidth])
		let rawHeight = dpiValue(properties?[kCGImagePropertyDPIHeight])
		let swapsAxes = orientationSwapsAxes(readOrientation(from: source))
		let dpiWidth = normalizedDPI(swapsAxes ? rawHeight : rawWidth)
		let dpiHeight = normalizedDPI(swapsAxes ? rawWidth : rawHeight)

		return CGRect(
			x: 0,
			y: 0,
			width: CGFloat(image.width) / CGFloat(dpiWidth) * 72,
			height: CGFloat(image.height) / CGFloat(dpiHeight) * 72
		)
	}

	private static func dpiValue(_ value: Any?) -> Double? {
		switch value {
		case let value as Double:
			return value
		case let value as Float:
			return Double(value)
		case let value as Int:
			return Double(value)
		case let value as NSNumber:
			return value.doubleValue
		default:
			return nil
		}
	}

	private static func normalizedDPI(_ value: Double?) -> Double {
		guard let value, value.isFinite, value >= 36, value <= 2400 else {
			return 72
		}
		return value
	}

	private static func orientationSwapsAxes(_ orientation: CGImagePropertyOrientation) -> Bool {
		switch orientation {
		case .left, .leftMirrored, .right, .rightMirrored:
			return true
		default:
			return false
		}
	}

	private static func makeVisibleImagePDF(image: CGImage, imageQuality: Double?) throws -> Data {
		let data = NSMutableData()
		guard
			let destination = CGImageDestinationCreateWithData(
				data as CFMutableData,
				"com.adobe.pdf" as CFString,
				1,
				nil
			)
		else {
			throw MessageError("Could not create PDF image destination")
		}

		let properties: [CFString: Any] = [
			kCGImagePropertyDPIWidth: 72,
			kCGImagePropertyDPIHeight: 72,
		]
		if let imageQuality {
			let jpegData = try encodeJPEG(image: image, quality: imageQuality)
			guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil) else {
				throw MessageError("Could not read compressed image layer")
			}
			CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
		} else {
			CGImageDestinationAddImage(destination, image, properties as CFDictionary)
		}
		guard CGImageDestinationFinalize(destination) else {
			throw MessageError("Could not encode PDF image layer")
		}
		return data as Data
	}

	private static func encodeJPEG(image: CGImage, quality: Double) throws -> Data {
		let data = NSMutableData()
		guard
			let destination = CGImageDestinationCreateWithData(
				data as CFMutableData,
				"public.jpeg" as CFString,
				1,
				nil
			)
		else {
			throw MessageError("Could not create compressed image destination")
		}
		let properties: [CFString: Any] = [
			kCGImageDestinationLossyCompressionQuality: quality,
			kCGImagePropertyDPIWidth: 72,
			kCGImagePropertyDPIHeight: 72,
		]
		CGImageDestinationAddImage(destination, image, properties as CFDictionary)
		guard CGImageDestinationFinalize(destination) else {
			throw MessageError("Could not encode compressed image layer")
		}
		return data as Data
	}

	private static func flattenOverWhite(_ image: CGImage) -> CGImage {
		guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst else {
			return image
		}
		guard
			let context = CGContext(
				data: nil,
				width: image.width,
				height: image.height,
				bitsPerComponent: 8,
				bytesPerRow: 0,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
			)
		else {
			return image
		}
		let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
		context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
		context.fill(rect)
		context.draw(image, in: rect)
		return context.makeImage() ?? image
	}

	/// Decode a full-resolution, EXIF-orientation-corrected (upright) image.
	/// ImageIO applies the orientation transform when
	/// `kCGImageSourceCreateThumbnailWithTransform` is set, so we never have to
	/// hand-roll the 8-case orientation matrix.
	private static func uprightImage(from source: CGImageSource) -> CGImage? {
		let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
		let pixelWidth = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
		let pixelHeight = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
		let maxDimension = max(pixelWidth, pixelHeight)
		guard maxDimension > 0 else {
			return CGImageSourceCreateImageAtIndex(source, 0, nil)
		}
		let options: [CFString: Any] = [
			kCGImageSourceCreateThumbnailWithTransform: true,
			kCGImageSourceCreateThumbnailFromImageAlways: true,
			kCGImageSourceThumbnailMaxPixelSize: maxDimension,
		]
		return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
			?? CGImageSourceCreateImageAtIndex(source, 0, nil)
	}

	// MARK: - OCR

	private static func recognize(_ image: CGImage, options: OCROptions) async throws -> OCRResult {
		// The invisible layer is positioned per word, so opt in to the
		// word-geometry computation the plain `ocr` path skips.
		let wordOptions: OCROptions = {
			var options = options
			options.includeWordGeometry = true
			return options
		}()
		let session = VisionSession(image: image, orientation: .up)
		return try await VisionRuntime.shared.run(session) { session in
			try recognizeText(in: session, options: wordOptions)
		}
	}

	/// Whether the page's content stream contains text-showing operators (`Tj`,
	/// `TJ`, `'`, `"`) — i.e. it already has a selectable text layer (a
	/// born-digital page). Image-only/scanned pages return false. Text inside
	/// referenced Form XObjects is not inspected; the common born-digital case
	/// draws text directly in the page stream.
	private static func pageHasTextLayer(_ page: CGPDFPage) -> Bool {
		let contentStream = CGPDFContentStreamCreateWithPage(page)
		defer { CGPDFContentStreamRelease(contentStream) }
		guard let operatorTable = CGPDFOperatorTableCreate() else {
			return false
		}
		defer { CGPDFOperatorTableRelease(operatorTable) }

		let callback: CGPDFOperatorCallback = { _, info in
			info?.assumingMemoryBound(to: Bool.self).pointee = true
		}
		for textOperator in ["Tj", "TJ", "'", "\""] {
			CGPDFOperatorTableSetCallback(operatorTable, textOperator, callback)
		}

		var hasText = false
		withUnsafeMutablePointer(to: &hasText) { pointer in
			let scanner = CGPDFScannerCreate(contentStream, operatorTable, UnsafeMutableRawPointer(pointer))
			CGPDFScannerScan(scanner)
			CGPDFScannerRelease(scanner)
		}
		return hasText
	}

	// MARK: - Page composition

	private static func writePage(
		mediaBox: CGRect,
		ocr: OCRResult,
		into context: CGContext,
		drawVisible: (CGContext) -> Void
	) {
		var box = mediaBox
		let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
		let pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: boxData]
		context.beginPDFPage(pageInfo as CFDictionary)

		// Visible layer: white background + original content.
		context.saveGState()
		context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
		context.fill(mediaBox)
		drawVisible(context)
		context.restoreGState()

		// Invisible, selectable text layer. One run per recognized *word*,
		// positioned from Vision's per-word geometry, so selection rectangles
		// track the printed words; observations without word geometry fall
		// back to a single line-level run.
		context.saveGState()
		context.setTextDrawingMode(.invisible)
		for observation in ocr.observations {
			if observation.words.isEmpty {
				drawInvisibleText(
					observation.text,
					normalizedBox: observation.boundingBox,
					mediaBox: mediaBox,
					into: context
				)
			} else {
				for word in observation.words {
					drawInvisibleText(
						word.text,
						normalizedBox: word.boundingBox,
						mediaBox: mediaBox,
						into: context
					)
				}
			}
		}
		context.restoreGState()

		context.endPDFPage()
	}

	/// Draw a single recognized string as invisible text positioned to its OCR
	/// bounding box. `BoundingBox` is normalized, top-left origin; PDF user
	/// space is bottom-left origin, so the y axis is flipped.
	private static func drawInvisibleText(
		_ text: String,
		normalizedBox box: BoundingBox,
		mediaBox: CGRect,
		into context: CGContext
	) {
		guard !text.isEmpty else { return }

		let boxHeight = CGFloat(box.height) * mediaBox.height
		guard boxHeight > 0 else { return }

		let originX = mediaBox.minX + CGFloat(box.x) * mediaBox.width
		let originY = mediaBox.minY + CGFloat(1 - box.y - box.height) * mediaBox.height

		let font = makeFont(size: boxHeight)
		let attributes: [NSAttributedString.Key: Any] = [
			NSAttributedString.Key(kCTFontAttributeName as String): font
		]
		let attributed = NSAttributedString(string: text, attributes: attributes)
		let line = CTLineCreateWithAttributedString(attributed)

		var ascent: CGFloat = 0
		var descent: CGFloat = 0
		var leading: CGFloat = 0
		_ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)

		// Draw at natural metrics (font size ≈ box height) with an identity
		// text matrix. Fitting a word to its box width would need a horizontal
		// scale, but under a non-unit text matrix Core Text serializes
		// per-glyph positioning that PDF text extractors read as inter-letter
		// spaces ("Hello" → "H e l l o"), breaking search. The breakage grows
		// with the scale factor: clean when the box ≈ the rendered text, but
		// splitting once the box is materially wider (common on sparse OCR
		// lines). So alignment instead comes from one run per word at that
		// word's own box (see writePage); within a run, width stays approximate.
		context.textMatrix = .identity
		context.textPosition = CGPoint(x: originX, y: originY + descent)
		CTLineDraw(line, context)
	}

	/// System UI font for the given size. Core Text performs font substitution
	/// during line layout, so non-Latin scripts get covered via the cascade.
	private static func makeFont(size: CGFloat) -> CTFont {
		let clamped = max(size, 1)
		if let system = CTFontCreateUIFontForLanguage(.system, clamped, nil) {
			return system
		}
		return CTFontCreateWithName("Helvetica" as CFString, clamped, nil)
	}
}
