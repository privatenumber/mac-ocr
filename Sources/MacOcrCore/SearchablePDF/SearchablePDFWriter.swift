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
	public struct DebugOptions: Sendable {
		public let jsonlURL: URL
		public let drawOverlay: Bool

		public init(jsonlURL: URL, drawOverlay: Bool = true) {
			self.jsonlURL = jsonlURL
			self.drawOverlay = drawOverlay
		}
	}

	public struct Warning: Sendable {
		public let message: String

		public init(message: String) {
			self.message = message
		}
	}

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
		imagePageDpi: Double? = nil,
		imageDownsampleDpi: Double? = nil,
		ocrStrategy: OCRStrategy = .auto,
		debugOptions: DebugOptions? = nil,
		onWarning: ((Warning) -> Void)? = nil,
		onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil
	) async throws -> Data {
		try validateImageQuality(imageQuality)
		try validateImageDPI(imagePageDpi, name: "--image-page-dpi")
		try validateImageDPI(imageDownsampleDpi, name: "--image-downsample-dpi")
		let producer = try await resolveProducer(
			source,
			password: password,
			imageQuality: imageQuality,
			imagePageDpi: imagePageDpi,
			imageDownsampleDpi: imageDownsampleDpi
		)
		let renderOptions = DebugRenderOptions(
			pdfDpi: pdfDpi,
			imagePageDpi: imagePageDpi,
			imageDownsampleDpi: imageDownsampleDpi,
			imageQuality: imageQuality
		)

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
				if let debugOptions {
					let debugWriter = try DebugWriter(options: debugOptions)
					defer { try? debugWriter.close() }
					try writeSkippedPDFDebugRecords(
						document: document,
						source: source,
						sourceIndex: 1,
						outputPageOffset: 0,
						outputPageCount: pageCount,
						ocrStrategy: ocrStrategy,
						renderOptions: renderOptions,
						writer: debugWriter
					)
				}
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

		let debugWriter = try debugOptions.map(DebugWriter.init(options:))
		defer { try? debugWriter?.close() }

		let pagesWritten = try await appendSource(
			producer, displayName: source.displayName, options: options, pdfDpi: pdfDpi,
			ocrAllPages: ocrAllPages, into: context,
			ocrStrategy: ocrStrategy,
			debugContext: debugWriter.map {
				DebugContext(
					writer: $0,
					source: source,
					sourceIndex: 1,
					outputPageOffset: 0,
					outputPageCount: nil,
					renderOptions: renderOptions
				)
			},
			onWarning: onWarning,
			onProgress: onProgress
		)

		guard pagesWritten > 0 else {
			throw MessageError("No pages were produced")
		}

		context.closePDF()
		return pdfData as Data
	}

	/// Render sources into one searchable PDF in the order they are passed.
	///
	/// Merged output always rewrites inputs into a new PDF document, so the
	/// single-PDF verbatim pass-through optimization does not apply.
	public static func renderMerged(
		sources: [ImageSource],
		options: OCROptions,
		pdfDpi: Int?,
		password: String? = nil,
		ocrAllPages: Bool = false,
		imageQuality: Double? = nil,
		imagePageDpi: Double? = nil,
		imageDownsampleDpi: Double? = nil,
		ocrStrategy: OCRStrategy = .auto,
		debugOptions: DebugOptions? = nil,
		onWarning: ((Warning) -> Void)? = nil,
		onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil
	) async throws -> Data {
		let pdfData = NSMutableData()
		guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
			let context = CGContext(consumer: consumer, mediaBox: nil, nil)
		else {
			throw MessageError("Could not create PDF output context")
		}

		let debugWriter = try debugOptions.map(DebugWriter.init(options:))
		defer { try? debugWriter?.close() }

		let completedPages = try await appendMergedSources(
			sources: sources,
			options: options,
			pdfDpi: pdfDpi,
			password: password,
			ocrAllPages: ocrAllPages,
			imageQuality: imageQuality,
			imagePageDpi: imagePageDpi,
			imageDownsampleDpi: imageDownsampleDpi,
			ocrStrategy: ocrStrategy,
			into: context,
			debugWriter: debugWriter,
			onWarning: onWarning,
			onProgress: onProgress
		)

		guard completedPages > 0 else {
			throw MessageError("No pages were produced")
		}

		context.closePDF()
		return pdfData as Data
	}

	public static func writeMerged(
		sources: [ImageSource],
		to outputURL: URL,
		options: OCROptions,
		pdfDpi: Int?,
		password: String? = nil,
		ocrAllPages: Bool = false,
		imageQuality: Double? = nil,
		imagePageDpi: Double? = nil,
		imageDownsampleDpi: Double? = nil,
		ocrStrategy: OCRStrategy = .auto,
		debugOptions: DebugOptions? = nil,
		onWarning: ((Warning) -> Void)? = nil,
		onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil
	) async throws {
		guard let consumer = CGDataConsumer(url: outputURL as CFURL),
			let context = CGContext(consumer: consumer, mediaBox: nil, nil)
		else {
			throw MessageError("Could not create PDF output context")
		}

		let debugWriter = try debugOptions.map(DebugWriter.init(options:))
		defer { try? debugWriter?.close() }

		let completedPages = try await appendMergedSources(
			sources: sources,
			options: options,
			pdfDpi: pdfDpi,
			password: password,
			ocrAllPages: ocrAllPages,
			imageQuality: imageQuality,
			imagePageDpi: imagePageDpi,
			imageDownsampleDpi: imageDownsampleDpi,
			ocrStrategy: ocrStrategy,
			into: context,
			debugWriter: debugWriter,
			onWarning: onWarning,
			onProgress: onProgress
		)

		guard completedPages > 0 else {
			throw MessageError("No pages were produced")
		}

		context.closePDF()
	}

	private static func appendMergedSources(
		sources: [ImageSource],
		options: OCROptions,
		pdfDpi: Int?,
		password: String?,
		ocrAllPages: Bool,
		imageQuality: Double?,
		imagePageDpi: Double?,
		imageDownsampleDpi: Double?,
		ocrStrategy: OCRStrategy,
		into context: CGContext,
		debugWriter: DebugWriter?,
		onWarning: ((Warning) -> Void)? = nil,
		onProgress: ((_ done: Int, _ total: Int) -> Void)? = nil
	) async throws -> Int {
		try validateImageQuality(imageQuality)
		try validateImageDPI(imagePageDpi, name: "--image-page-dpi")
		try validateImageDPI(imageDownsampleDpi, name: "--image-downsample-dpi")
		guard !sources.isEmpty else {
			throw MessageError("No input sources were provided")
		}

		var plans: [MergeSourcePlan] = []
		plans.reserveCapacity(sources.count)
		for source in sources {
			plans.append(try await mergeSourcePlan(for: source, password: password))
		}
		let totalPages = plans.reduce(0) { $0 + $1.pageCount }

		onProgress?(0, totalPages)
		var completedBeforeSource = 0
		for (index, plan) in plans.enumerated() {
			let renderOptions = DebugRenderOptions(
				pdfDpi: pdfDpi,
				imagePageDpi: imagePageDpi,
				imageDownsampleDpi: imageDownsampleDpi,
				imageQuality: imageQuality
			)
			let producer = try await resolveProducer(
				plan: plan,
				password: password,
				imageQuality: imageQuality,
				imagePageDpi: imagePageDpi,
				imageDownsampleDpi: imageDownsampleDpi
			)
			let pagesWritten = try await appendSource(
				producer,
				displayName: plan.source.displayName,
				options: options,
				pdfDpi: pdfDpi,
				ocrAllPages: ocrAllPages,
				into: context,
				ocrStrategy: ocrStrategy,
				debugContext: debugWriter.map {
					DebugContext(
						writer: $0,
						source: plan.source,
						sourceIndex: index + 1,
						outputPageOffset: completedBeforeSource,
						outputPageCount: totalPages,
						renderOptions: renderOptions
					)
				},
				onWarning: onWarning,
				onProgress: { done, _ in
					if done > 0 {
						onProgress?(completedBeforeSource + done, totalPages)
					}
				}
			)
			completedBeforeSource += pagesWritten
		}
		return completedBeforeSource
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

	private struct MergeSourcePlan {
		let source: ImageSource
		let pageCount: Int
		let data: Data?
	}

	private struct DebugContext {
		let writer: DebugWriter
		let source: ImageSource
		let sourceIndex: Int
		let outputPageOffset: Int
		let outputPageCount: Int?
		let renderOptions: DebugRenderOptions
	}

	private struct DebugRenderOptions {
		let pdfDpi: Int?
		let imagePageDpi: Double?
		let imageDownsampleDpi: Double?
		let imageQuality: Double?
	}

	private final class DebugWriter {
		let options: DebugOptions
		private let handle: FileHandle

		init(options: DebugOptions) throws {
			self.options = options
			try FileManager.default.createDirectory(
				at: options.jsonlURL.deletingLastPathComponent(),
				withIntermediateDirectories: true
			)
			FileManager.default.createFile(atPath: options.jsonlURL.path, contents: nil)
			handle = try FileHandle(forWritingTo: options.jsonlURL)
			try handle.truncate(atOffset: 0)
		}

		func write(_ record: DebugPageRecord) throws {
			let line = try encodeJSONLine(record) + "\n"
			if #available(macOS 10.15.4, *) {
				try handle.write(contentsOf: Data(line.utf8))
			} else {
				handle.write(Data(line.utf8))
			}
		}

		func close() throws {
			if #available(macOS 10.15.4, *) {
				try handle.close()
			} else {
				handle.closeFile()
			}
		}
	}

	private struct DebugPageRecord: Encodable {
		let schema = "mac-ocr.searchable-pdf.debug"
		let schemaVersion = 2
		let source: DebugSource
		let output: DebugOutput
		let geometry: DebugGeometry
		let recognition: DebugRecognition
		let ocr: DebugOCR
	}

	private struct RecognizedPage {
		let ocr: OCRResult
		let debug: DebugRecognizedPage
	}

	private struct DebugRecognizedPage {
		let recognition: DebugRecognition
		let observations: [DebugOCRObservation]
	}

	private struct DebugSource: Encodable {
		let input: ImageSource
		let index: Int
		let page: Int
		let pageCount: Int
	}

	private struct DebugOutput: Encodable {
		let page: Int
		let pageCount: Int
	}

	private struct DebugGeometry: Encodable {
		let ocrImage: DebugImageSize?
		let pdfPage: DebugPDFPage
		let render: DebugRender
		let coordinates = DebugCoordinates()
	}

	private struct DebugRender: Encodable {
		let effectiveImageDpi: DebugDPI?
		let requestedPdfDpi: Int?
		let imagePageDpi: Double?
		let imageDownsampleDpi: Double?
		let imageQuality: Double?
	}

	private struct DebugDPI: Encodable {
		let width: Double
		let height: Double
	}

	private struct DebugCoordinates: Encodable {
		let boundingBox = DebugCoordinateSpace(
			units: "normalized",
			origin: "top-left",
			relativeTo: "ocrImage"
		)
		let pdfBox = DebugCoordinateSpace(
			units: "points",
			origin: "bottom-left",
			relativeTo: "pdfPage"
		)
	}

	private struct DebugCoordinateSpace: Encodable {
		let units: String
		let origin: String
		let relativeTo: String
	}

	private struct DebugRecognition: Encodable {
		let strategy: String
		let effectiveStrategy: String
		let skipped: Bool
		let skipReason: String?
		let passes: DebugPasses
	}

	private struct DebugPasses: Encodable {
		let full: DebugFullPass?
		let partitioned: DebugPartitionedPass?
	}

	private struct DebugFullPass: Encodable {
		let type = "full-page"
		let enabled: Bool
		let observationCount: Int
	}

	private struct DebugPartitionedPass: Encodable {
		let type = "partitioned"
		let enabled: Bool
		let reason: String
		let algorithm: String?
		let partitionCount: Int?
		let metrics: DebugOCRMetrics
		let thresholds: DebugPartitionThresholds
		let partitions: [DebugPartitionSummary]?
	}

	private struct DebugOCRMetrics: Encodable {
		let megapixels: Double?
		let maxDimension: Int?
		let medianTextHeight: Double?
		let p25TextHeight: Double?

		init(_ metrics: OCRMetrics) {
			megapixels = metrics.megapixels
			maxDimension = metrics.maxDimension
			medianTextHeight = metrics.medianTextHeight
			p25TextHeight = metrics.p25TextHeight
		}
	}

	private struct DebugPartitionThresholds: Encodable {
		let minMegapixels = SearchablePDF.autoMinMegapixels
		let minMaxDimension = SearchablePDF.autoMinMaxDimension
		let medianTextHeight = SearchablePDF.smallTextMedianThreshold
		let p25TextHeight = SearchablePDF.smallTextP25Threshold
		let minPartitionMegapixels = SearchablePDF.minPartitionMegapixels
		let minPartitionMaxDimension = SearchablePDF.minPartitionMaxDimension
		let minPartitionTextLength = SearchablePDF.minPartitionTextLength
		let minPartitionConfidence = SearchablePDF.minPartitionConfidence
	}

	private struct DebugPartitionSummary: Encodable {
		let id: String
		let depth: Int
		let box: BoundingBox
		let raw: Int
		let accepted: Int
		let rejected: Int
	}

	private struct DebugImageSize: Encodable {
		let width: Int
		let height: Int
	}

	private struct DebugPDFPage: Encodable {
		let mediaBox: DebugRect
		let rotation: Int
	}

	private struct DebugRect: Encodable {
		let x: Double
		let y: Double
		let width: Double
		let height: Double

		init(_ rect: CGRect) {
			x = Double(rect.origin.x)
			y = Double(rect.origin.y)
			width = Double(rect.width)
			height = Double(rect.height)
		}
	}

	private struct DebugOCR: Encodable {
		let text: String
		let observations: [DebugObservationRecord]

		init(ocr: OCRResult, observations: [DebugOCRObservation], mediaBox: CGRect) {
			text = ocr.text
			self.observations = observations.map { observation in
				DebugObservationRecord(observation: observation, mediaBox: mediaBox)
			}
		}
	}

	private struct DebugObservationRecord: Encodable {
		let id: Int
		let status: String
		let text: String
		let confidence: Float
		let requestRevision: Int
		let boundingBox: BoundingBox
		let pdfBox: DebugRect?
		let origin: DebugObservationOrigin
		let rejection: DebugRejection?
		let candidates: [TextCandidate]?
		let words: [DebugWord]?

		init(observation: DebugOCRObservation, mediaBox: CGRect) {
			id = observation.id
			status = observation.status.rawValue
			text = observation.observation.text
			confidence = observation.observation.confidence
			requestRevision = observation.observation.requestRevision
			boundingBox = observation.observation.boundingBox
			if observation.status.isAccepted {
				pdfBox = DebugRect(SearchablePDF.pdfRect(normalizedBox: observation.observation.boundingBox, mediaBox: mediaBox))
			} else {
				pdfBox = nil
			}
			origin = DebugObservationOrigin(observation: observation)
			rejection = observation.status.rejection
			candidates = observation.observation.candidates.isEmpty ? nil : observation.observation.candidates
			words = observation.observation.words.isEmpty ? nil : observation.observation.words.map(DebugWord.init(word:))
		}
	}

	private struct DebugObservationOrigin: Encodable {
		let passId: String
		let partitionId: String?
		let depth: Int?
		let edgeTouching: Bool?

		init(observation: DebugOCRObservation) {
			let source = observation.observation.source
			passId = source?.pass ?? "full"
			partitionId = observation.partitionId
			depth = source?.depth
			edgeTouching = passId == "partition" ? source?.edgeTouching ?? false : nil
		}
	}

	private struct DebugOCRObservation {
		let id: Int
		let partitionId: String?
		let observation: Observation
		var status: DebugObservationStatus
	}

	private enum DebugObservationStatus {
		case accepted
		case rejected(DebugRejection)

		var rawValue: String {
			switch self {
			case .accepted: return "accepted"
			case .rejected: return "rejected"
			}
		}

		var isAccepted: Bool {
			if case .accepted = self { return true }
			return false
		}

		var rejection: DebugRejection? {
			if case .rejected(let rejection) = self { return rejection }
			return nil
		}
	}

	private struct DebugRejection: Encodable {
		let reason: String
		let supersededBy: Int?
		let detail: DebugRejectionDetail?
	}

	private struct DebugRejectionDetail: Encodable {
		let iou: Double?
		let intersectionOverSmallerArea: Double?
		let rejectedScore: Double?
		let keptScore: Double?
		let textLength: Int?
		let minimumTextLength: Int?
		let textHeight: Double?
		let minimumTextHeight: Float?
		let confidence: Float?
		let minimumConfidence: Float?

		init(
			iou: Double? = nil,
			intersectionOverSmallerArea: Double? = nil,
			rejectedScore: Double? = nil,
			keptScore: Double? = nil,
			textLength: Int? = nil,
			minimumTextLength: Int? = nil,
			textHeight: Double? = nil,
			minimumTextHeight: Float? = nil,
			confidence: Float? = nil,
			minimumConfidence: Float? = nil
		) {
			self.iou = iou
			self.intersectionOverSmallerArea = intersectionOverSmallerArea
			self.rejectedScore = rejectedScore
			self.keptScore = keptScore
			self.textLength = textLength
			self.minimumTextLength = minimumTextLength
			self.textHeight = textHeight
			self.minimumTextHeight = minimumTextHeight
			self.confidence = confidence
			self.minimumConfidence = minimumConfidence
		}
	}

	private struct DebugMergeRejection {
		let observation: DebugOCRObservation
		let rejection: DebugRejection
	}

	private struct DebugPartitionStats {
		let id: String
		let depth: Int
		let box: BoundingBox
		let raw: Int
	}

	private struct DebugWord: Encodable {
		let text: String
		let boundingBox: BoundingBox

		init(word: WordBox) {
			text = word.text
			boundingBox = word.boundingBox
		}
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

	private static func mergeSourcePlan(for source: ImageSource, password: String?) async throws -> MergeSourcePlan {
		switch source {
		case .file(let path):
			let url = URL(fileURLWithPath: path)
			guard FileManager.default.fileExists(atPath: url.path) else {
				throw MessageError("No such file: \(path)")
			}
			guard isPDFFile(url: url) else {
				return MergeSourcePlan(source: source, pageCount: 1, data: nil)
			}
			guard let document = CGPDFDocument(url as CFURL) else {
				throw MessageError("Cannot read PDF: \(path)")
			}
			try unlockPDF(document, password: password, label: path)
			let pageCount = document.numberOfPages
			guard pageCount > 0 else {
				throw MessageError("PDF has no pages: \(path)")
			}
			return MergeSourcePlan(source: source, pageCount: pageCount, data: nil)

		case .url(let urlString):
			guard let remoteURL = URL(string: urlString) else {
				throw MessageError("Invalid URL: \(urlString)")
			}
			let data = try await fetchRemoteData(from: remoteURL, label: urlString)
			guard isPDFData(data) else {
				return MergeSourcePlan(source: source, pageCount: 1, data: data)
			}
			guard let provider = CGDataProvider(data: data as CFData),
				let document = CGPDFDocument(provider)
			else {
				throw MessageError("Cannot read PDF from \(urlString)")
			}
			try unlockPDF(document, password: password, label: urlString)
			let pageCount = document.numberOfPages
			guard pageCount > 0 else {
				throw MessageError("PDF has no pages: \(urlString)")
			}
			return MergeSourcePlan(source: source, pageCount: pageCount, data: data)

		case .stdin:
			throw MessageError("--merge does not support stdin input")
		}
	}

	private static func writeSkippedPDFDebugRecords(
		document: CGPDFDocument,
		source: ImageSource,
		sourceIndex: Int,
		outputPageOffset: Int,
		outputPageCount: Int,
		ocrStrategy: OCRStrategy,
		renderOptions: DebugRenderOptions,
		writer: DebugWriter
	) throws {
		let sourcePageCount = document.numberOfPages
		let skipped = skippedPage(strategy: ocrStrategy, reason: "existing-text-layer")
		for pageNumber in 1...sourcePageCount {
			guard let page = document.page(at: pageNumber) else {
				throw MessageError("Could not load PDF page \(pageNumber)")
			}
			let mediaBox = page.getBoxRect(.mediaBox)
			try writer.write(
				debugRecord(
					context: DebugContext(
						writer: writer,
						source: source,
						sourceIndex: sourceIndex,
						outputPageOffset: outputPageOffset,
						outputPageCount: outputPageCount,
						renderOptions: renderOptions
					),
					sourcePage: pageNumber,
					sourcePageCount: sourcePageCount,
					outputPage: outputPageOffset + pageNumber,
					outputPageCount: outputPageCount,
					ocrImage: nil,
					mediaBox: mediaBox,
					pdfRotation: Int(page.rotationAngle),
					result: skipped
				))
		}
	}

	private static func resolveProducer(
		plan: MergeSourcePlan,
		password: String?,
		imageQuality: Double?,
		imagePageDpi: Double?,
		imageDownsampleDpi: Double?
	) async throws -> PageProducer {
		if let data = plan.data {
			return try producer(
				fromData: data,
				label: plan.source.displayName,
				password: password,
				imageQuality: imageQuality,
				imagePageDpi: imagePageDpi,
				imageDownsampleDpi: imageDownsampleDpi
			)
		}
		return try await resolveProducer(
			plan.source,
			password: password,
			imageQuality: imageQuality,
			imagePageDpi: imagePageDpi,
			imageDownsampleDpi: imageDownsampleDpi
		)
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
		ocrStrategy: OCRStrategy,
		debugContext: DebugContext? = nil,
		onWarning: ((Warning) -> Void)? = nil,
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
				let displayBox = displayBox(for: page)
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
				let result: RecognizedPage
				let ocrImage: DebugImageSize?
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
					ocrImage = DebugImageSize(width: raster.width, height: raster.height)
					result = try await recognize(raster, options: options, ocrStrategy: ocrStrategy, onWarning: onWarning)
				} else {
					ocrImage = nil
					result = skippedPage(strategy: ocrStrategy, reason: "existing-text-layer")
				}

				writePage(
					mediaBox: plan.displayBox,
					ocr: result.ocr,
					into: context,
					debugOverlay: debugContext?.writer.options.drawOverlay == true,
					debugObservations: result.debug.observations
				) { context in
					context.concatenate(plan.drawingTransform)
					context.drawPDFPage(plan.page)
				}
				try debugContext?.writer.write(
					debugRecord(
						context: debugContext,
						sourcePage: plan.pageNumber,
						sourcePageCount: pageCount,
						outputPage: (debugContext?.outputPageOffset ?? 0) + index + 1,
						outputPageCount: debugContext?.outputPageCount ?? pageCount,
						ocrImage: ocrImage,
						mediaBox: plan.displayBox,
						result: result
					))
				onProgress?(index + 1, pageCount)
			}
			return pageCount

		case .image(let page):
			onProgress?(0, 1)
			let image = page.image
			let mediaBox = page.mediaBox
			let result = try await recognize(image, options: options, ocrStrategy: ocrStrategy, onWarning: onWarning)
			writePage(
				mediaBox: mediaBox,
				ocr: result.ocr,
				into: context,
				debugOverlay: debugContext?.writer.options.drawOverlay == true,
				debugObservations: result.debug.observations
			) { context in
				context.concatenate(
					page.visiblePDFPage.getDrawingTransform(
						.cropBox, rect: mediaBox, rotate: 0, preserveAspectRatio: false
					))
				context.drawPDFPage(page.visiblePDFPage)
			}
			try debugContext?.writer.write(
				debugRecord(
					context: debugContext,
					sourcePage: 1,
					sourcePageCount: 1,
					outputPage: (debugContext?.outputPageOffset ?? 0) + 1,
					outputPageCount: debugContext?.outputPageCount ?? 1,
					ocrImage: DebugImageSize(width: image.width, height: image.height),
					mediaBox: mediaBox,
					result: result
				))
			onProgress?(1, 1)
			return 1
		}
	}

	private static func resolveProducer(
		_ source: ImageSource,
		password: String?,
		imageQuality: Double?,
		imagePageDpi: Double?,
		imageDownsampleDpi: Double?
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
			return .image(
				try imagePage(
					from: source,
					label: path,
					imageQuality: imageQuality,
					imagePageDpi: imagePageDpi,
					imageDownsampleDpi: imageDownsampleDpi
				))

		case .url(let urlString):
			guard let remoteURL = URL(string: urlString) else {
				throw MessageError("Invalid URL: \(urlString)")
			}
			let data = try await fetchRemoteData(from: remoteURL, label: urlString)
			return try producer(
				fromData: data,
				label: urlString,
				password: password,
				imageQuality: imageQuality,
				imagePageDpi: imagePageDpi,
				imageDownsampleDpi: imageDownsampleDpi
			)

		case .stdin:
			let data = try readAllStandardInput()
			guard !data.isEmpty else {
				throw MessageError("No data received on stdin")
			}
			return try producer(
				fromData: data,
				label: "stdin",
				password: password,
				imageQuality: imageQuality,
				imagePageDpi: imagePageDpi,
				imageDownsampleDpi: imageDownsampleDpi
			)
		}
	}

	private static func producer(
		fromData data: Data,
		label: String,
		password: String?,
		imageQuality: Double?,
		imagePageDpi: Double?,
		imageDownsampleDpi: Double?
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
		return .image(
			try imagePage(
				from: source,
				label: label,
				imageQuality: imageQuality,
				imagePageDpi: imagePageDpi,
				imageDownsampleDpi: imageDownsampleDpi
			))
	}

	private static func validateImageQuality(_ value: Double?) throws {
		guard let value else { return }
		guard value.isFinite, value >= 0, value <= 1 else {
			throw MessageError("--image-quality must be between 0.0 and 1.0")
		}
	}

	private static func validateImageDPI(_ value: Double?, name: String) throws {
		guard let value else { return }
		guard value.isFinite, value >= 36, value <= 2400 else {
			throw MessageError("\(name) must be between 36 and 2400")
		}
	}

	private static func imagePage(
		from source: CGImageSource,
		label: String,
		imageQuality: Double?,
		imagePageDpi: Double?,
		imageDownsampleDpi: Double?
	) throws -> ImagePage {
		guard let image = uprightImage(from: source) else {
			throw MessageError("Cannot read image from \(label)")
		}
		let mediaBox = imageMediaBox(source: source, image: image, imagePageDpi: imagePageDpi)
		let downsampled = downsampleVisibleImage(
			image,
			mediaBox: mediaBox,
			imageDownsampleDpi: imageDownsampleDpi
		)
		let visibleImage = imageQuality == nil ? downsampled : flattenOverWhite(downsampled)
		let data = try makeVisibleImagePDF(image: visibleImage, imageQuality: imageQuality)
		guard let provider = CGDataProvider(data: data as CFData),
			let document = CGPDFDocument(provider),
			let page = document.page(at: 1)
		else {
			throw MessageError("Could not create PDF image layer for \(label)")
		}
		return ImagePage(
			image: image,
			mediaBox: mediaBox,
			visiblePDFData: data,
			visiblePDFDocument: document,
			visiblePDFPage: page
		)
	}

	private static func imageMediaBox(source: CGImageSource, image: CGImage, imagePageDpi: Double?) -> CGRect {
		if let imagePageDpi {
			return CGRect(
				x: 0,
				y: 0,
				width: CGFloat(image.width) / CGFloat(imagePageDpi) * 72,
				height: CGFloat(image.height) / CGFloat(imagePageDpi) * 72
			)
		}

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

	private static func debugRecord(
		context: DebugContext?,
		sourcePage: Int,
		sourcePageCount: Int,
		outputPage: Int,
		outputPageCount: Int,
		ocrImage: DebugImageSize?,
		mediaBox: CGRect,
		pdfRotation: Int = 0,
		result: RecognizedPage
	) -> DebugPageRecord {
		let renderOptions =
			context?.renderOptions
			?? DebugRenderOptions(
				pdfDpi: nil,
				imagePageDpi: nil,
				imageDownsampleDpi: nil,
				imageQuality: nil
			)
		return DebugPageRecord(
			source: DebugSource(
				input: context?.source ?? .stdin,
				index: context?.sourceIndex ?? 1,
				page: sourcePage,
				pageCount: sourcePageCount
			),
			output: DebugOutput(page: outputPage, pageCount: outputPageCount),
			geometry: DebugGeometry(
				ocrImage: ocrImage,
				pdfPage: DebugPDFPage(mediaBox: DebugRect(mediaBox), rotation: pdfRotation),
				render: debugRender(ocrImage: ocrImage, mediaBox: mediaBox, options: renderOptions)
			),
			recognition: result.debug.recognition,
			ocr: DebugOCR(ocr: result.ocr, observations: result.debug.observations, mediaBox: mediaBox)
		)
	}

	private static func debugRender(ocrImage: DebugImageSize?, mediaBox: CGRect, options: DebugRenderOptions) -> DebugRender {
		let dpi: DebugDPI?
		if let ocrImage, mediaBox.width > 0, mediaBox.height > 0 {
			dpi = DebugDPI(
				width: Double(ocrImage.width) / Double(mediaBox.width) * 72,
				height: Double(ocrImage.height) / Double(mediaBox.height) * 72
			)
		} else {
			dpi = nil
		}
		return DebugRender(
			effectiveImageDpi: dpi,
			requestedPdfDpi: options.pdfDpi,
			imagePageDpi: options.imagePageDpi,
			imageDownsampleDpi: options.imageDownsampleDpi,
			imageQuality: options.imageQuality
		)
	}

	private static func displayBox(for page: CGPDFPage) -> CGRect {
		let cropBox = page.getBoxRect(.cropBox)
		// Widen to Int before abs: abs(Int32.min) traps on a hostile /Rotate.
		let rotated = abs(Int(page.rotationAngle)) % 180 == 90
		return CGRect(
			x: 0,
			y: 0,
			width: rotated ? cropBox.height : cropBox.width,
			height: rotated ? cropBox.width : cropBox.height
		)
	}

	private static func downsampleVisibleImage(
		_ image: CGImage,
		mediaBox: CGRect,
		imageDownsampleDpi: Double?
	) -> CGImage {
		guard let imageDownsampleDpi else { return image }
		let targetWidth = min(
			image.width,
			Int((mediaBox.width / 72 * CGFloat(imageDownsampleDpi)).rounded(.up))
		)
		let targetHeight = min(
			image.height,
			Int((mediaBox.height / 72 * CGFloat(imageDownsampleDpi)).rounded(.up))
		)
		guard targetWidth > 0, targetHeight > 0,
			targetWidth < image.width || targetHeight < image.height
		else {
			return image
		}

		guard
			let context = CGContext(
				data: nil,
				width: targetWidth,
				height: targetHeight,
				bitsPerComponent: 8,
				bytesPerRow: 0,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			)
		else {
			return image
		}
		let rect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
		context.interpolationQuality = .high
		context.clear(rect)
		context.draw(image, in: rect)
		return context.makeImage() ?? image
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

	private static func recognize(
		_ image: CGImage,
		options: OCROptions,
		ocrStrategy: OCRStrategy,
		onWarning: ((Warning) -> Void)? = nil
	) async throws -> RecognizedPage {
		// The invisible layer is positioned per word, so opt in to the
		// word-geometry computation the plain `ocr` path skips.
		let wordOptions: OCROptions = {
			var options = options
			options.includeWordGeometry = true
			return options
		}()
		let full = try await recognize(image, options: wordOptions, source: ObservationSource(pass: "full"))
		let decision = partitionDecision(strategy: ocrStrategy, image: image, fullResult: full, options: wordOptions)
		let fullDebugObservations = full.observations.enumerated().map { index, observation in
			DebugOCRObservation(id: index + 1, partitionId: nil, observation: observation, status: .accepted)
		}
		guard decision.enabled else {
			let recognition = debugRecognition(
				strategy: ocrStrategy,
				effectiveStrategy: "standard",
				decision: decision,
				fullObservationCount: full.observations.count,
				partitions: nil
			)
			return RecognizedPage(
				ocr: full,
				debug: DebugRecognizedPage(recognition: recognition, observations: fullDebugObservations)
			)
		}
		if estimatedPartitionPasses(image: image, limit: partitionWarningEstimatedPasses) >= partitionWarningEstimatedPasses {
			onWarning?(partitionWarning(image: image))
		}
		return try await recognizePartitioned(
			image,
			options: wordOptions,
			fullResult: full,
			fullDebugObservations: fullDebugObservations,
			decision: decision
		)
	}

	private static func recognize(_ image: CGImage, options: OCROptions, source: ObservationSource) async throws -> OCRResult {
		let session = VisionSession(image: image, orientation: .up)
		let result = try await VisionRuntime.shared.run(session) { session in
			try recognizeText(in: session, options: options)
		}
		return withSource(source, result: result)
	}

	private static func recognizePartitioned(
		_ image: CGImage,
		options: OCROptions,
		fullResult: OCRResult,
		fullDebugObservations: [DebugOCRObservation],
		decision: PartitionDecision
	) async throws -> RecognizedPage {
		var acceptedObservations = fullDebugObservations
		var debugObservations = fullDebugObservations
		var queue = split(Partition(box: BoundingBox(x: 0, y: 0, width: 1, height: 1), depth: 0), image: image)
		var partitionCount = 0
		var partitionStats: [DebugPartitionStats] = []
		var nextObservationId = fullDebugObservations.count + 1

		while !queue.isEmpty {
			let partition = queue.removeFirst()
			guard let partitionImage = crop(image, to: partition.box) else { continue }
			partitionCount += 1
			let partitionId = "p\(partitionCount)"
			let localResult = try await recognize(
				partitionImage,
				options: options,
				source: ObservationSource(pass: "partition", partition: partition.box, edgeTouching: false, depth: partition.depth)
			)
			partitionStats.append(
				DebugPartitionStats(
					id: partitionId,
					depth: partition.depth,
					box: partition.box,
					raw: localResult.observations.count
				)
			)
			for observation in localResult.observations {
				let remapped = remap(observation, from: partition)
				var debugObservation = DebugOCRObservation(
					id: nextObservationId,
					partitionId: partitionId,
					observation: remapped,
					status: .accepted
				)
				nextObservationId += 1
				if let rejection = partitionRejection(for: remapped, options: options) {
					debugObservation.status = .rejected(rejection)
					debugObservations.append(debugObservation)
					continue
				}
				if let rejected = merge(debugObservation, into: &acceptedObservations) {
					if rejected.observation.id == debugObservation.id {
						debugObservation.status = .rejected(rejected.rejection)
						debugObservations.append(debugObservation)
					} else {
						rejectObservation(id: rejected.observation.id, rejection: rejected.rejection, in: &debugObservations)
						debugObservations.append(debugObservation)
					}
				} else {
					debugObservations.append(debugObservation)
				}
			}

			if shouldSplitPartition(localResult, image: partitionImage, options: options) {
				queue.append(contentsOf: split(partition, image: image))
			}
		}

		let sorted = acceptedObservations.map(\.observation).sorted { lhs, rhs in
			if abs(lhs.boundingBox.y - rhs.boundingBox.y) > 0.01 {
				return lhs.boundingBox.y < rhs.boundingBox.y
			}
			return lhs.boundingBox.x < rhs.boundingBox.x
		}
		let recognition = debugRecognition(
			strategy: decision.strategy,
			effectiveStrategy: "partitioned",
			decision: decision,
			fullObservationCount: fullResult.observations.count,
			partitions: partitionSummaries(from: partitionStats, observations: debugObservations)
		)
		return RecognizedPage(
			ocr: OCRResult(text: sorted.map(\.text).joined(separator: "\n"), observations: sorted),
			debug: DebugRecognizedPage(recognition: recognition, observations: debugObservations)
		)
	}

	private struct PartitionDecision {
		let enabled: Bool
		let strategy: OCRStrategy
		let reason: String
		let metrics: OCRMetrics
	}

	private struct Partition {
		let box: BoundingBox
		let depth: Int
	}

	// Vision does not publish its text recognizer's internal working resolution.
	// A representative lease scan preserved useful recall once child regions
	// landed in the low-single-digit megapixel range; split parents only while
	// they are large enough for their children to stay near that range.
	private static let minPartitionMegapixels = 8.0
	private static let minPartitionMaxDimension = 2800
	private static let autoMinMegapixels = 8.0
	private static let autoMinMaxDimension = 2500
	private static let smallTextP25Threshold = 0.015
	private static let smallTextMedianThreshold = 0.02
	private static let minPartitionTextLength = 2
	private static let minPartitionConfidence: Float = 0.3
	private static let partitionWarningEstimatedPasses = 32

	private static func crop(_ image: CGImage, to partition: BoundingBox) -> CGImage? {
		let rect = CGRect(
			x: CGFloat(partition.x) * CGFloat(image.width),
			y: CGFloat(partition.y) * CGFloat(image.height),
			width: CGFloat(partition.width) * CGFloat(image.width),
			height: CGFloat(partition.height) * CGFloat(image.height)
		).integral
		return image.cropping(to: rect)
	}

	private static func partitionDecision(
		strategy: OCRStrategy,
		image: CGImage,
		fullResult: OCRResult,
		options: OCROptions
	) -> PartitionDecision {
		let metrics = ocrMetrics(image: image, result: fullResult)
		if options.regionOfInterest != nil {
			return decision(strategy: strategy, enabled: false, reason: "roi-set", metrics: metrics)
		}
		switch strategy {
		case .standard:
			return decision(strategy: strategy, enabled: false, reason: "standard", metrics: metrics)
		case .partitioned:
			return decision(strategy: strategy, enabled: true, reason: "forced", metrics: metrics)
		case .auto:
			guard metrics.megapixels >= autoMinMegapixels || metrics.maxDimension >= autoMinMaxDimension else {
				return decision(strategy: strategy, enabled: false, reason: "image-small", metrics: metrics)
			}
			guard !fullResult.observations.isEmpty else {
				return decision(strategy: strategy, enabled: true, reason: "large-image-no-text", metrics: metrics)
			}
			if (metrics.p25TextHeight ?? 1) < smallTextP25Threshold {
				return decision(strategy: strategy, enabled: true, reason: "large-image-small-p25-text", metrics: metrics)
			}
			if (metrics.medianTextHeight ?? 1) < smallTextMedianThreshold {
				return decision(strategy: strategy, enabled: true, reason: "large-image-small-median-text", metrics: metrics)
			}
			return decision(strategy: strategy, enabled: false, reason: "text-large-enough", metrics: metrics)
		}
	}

	private static func decision(strategy: OCRStrategy, enabled: Bool, reason: String, metrics: OCRMetrics) -> PartitionDecision {
		PartitionDecision(enabled: enabled, strategy: strategy, reason: reason, metrics: metrics)
	}

	private static func partitionWarning(image: CGImage) -> Warning {
		let megapixels = Double(image.width * image.height) / 1_000_000
		return Warning(
			message: String(
				format: "very large image (%dx%d, %.1f MP); partitioned OCR may take a while",
				image.width,
				image.height,
				megapixels
			)
		)
	}

	private static func estimatedPartitionPasses(image: CGImage, limit: Int) -> Int {
		var queue = split(Partition(box: BoundingBox(x: 0, y: 0, width: 1, height: 1), depth: 0), image: image)
		var passes = 0
		while !queue.isEmpty, passes < limit {
			let partition = queue.removeFirst()
			passes += 1
			let width = Int((Double(image.width) * partition.box.width).rounded())
			let height = Int((Double(image.height) * partition.box.height).rounded())
			guard shouldSplitPartitionImage(width: width, height: height) else { continue }
			queue.append(contentsOf: split(partition, image: image))
		}
		return passes
	}

	private static func skippedPage(strategy: OCRStrategy, reason: String) -> RecognizedPage {
		let recognition = DebugRecognition(
			strategy: strategy.rawValue,
			effectiveStrategy: "skipped",
			skipped: true,
			skipReason: reason,
			passes: DebugPasses(full: nil, partitioned: nil)
		)
		return RecognizedPage(
			ocr: OCRResult(text: "", observations: []),
			debug: DebugRecognizedPage(recognition: recognition, observations: [])
		)
	}

	private static func debugRecognition(
		strategy: OCRStrategy,
		effectiveStrategy: String,
		decision: PartitionDecision,
		fullObservationCount: Int,
		partitions: [DebugPartitionSummary]?
	) -> DebugRecognition {
		DebugRecognition(
			strategy: strategy.rawValue,
			effectiveStrategy: effectiveStrategy,
			skipped: false,
			skipReason: nil,
			passes: DebugPasses(
				full: DebugFullPass(enabled: true, observationCount: fullObservationCount),
				partitioned: DebugPartitionedPass(
					enabled: decision.enabled,
					reason: decision.reason,
					algorithm: decision.enabled ? "recursive-bisection" : nil,
					partitionCount: decision.enabled ? partitions?.count ?? 0 : nil,
					metrics: DebugOCRMetrics(decision.metrics),
					thresholds: DebugPartitionThresholds(),
					partitions: partitions?.isEmpty == false ? partitions : nil
				)
			)
		)
	}

	private static func partitionSummaries(
		from stats: [DebugPartitionStats],
		observations: [DebugOCRObservation]
	) -> [DebugPartitionSummary] {
		stats.map { stat in
			var accepted = 0
			var rejected = 0
			for observation in observations where observation.partitionId == stat.id {
				if observation.status.isAccepted {
					accepted += 1
				} else {
					rejected += 1
				}
			}
			return DebugPartitionSummary(
				id: stat.id,
				depth: stat.depth,
				box: stat.box,
				raw: stat.raw,
				accepted: accepted,
				rejected: rejected
			)
		}
	}

	private static func rejectObservation(
		id: Int,
		rejection: DebugRejection,
		in observations: inout [DebugOCRObservation]
	) {
		for index in observations.indices where observations[index].id == id {
			observations[index].status = .rejected(rejection)
			return
		}
	}

	private struct OCRMetrics {
		let megapixels: Double
		let maxDimension: Int
		let medianTextHeight: Double?
		let p25TextHeight: Double?
	}

	private static func ocrMetrics(image: CGImage, result: OCRResult) -> OCRMetrics {
		let heights = result.observations.map(\.boundingBox.height).sorted()
		return OCRMetrics(
			megapixels: Double(image.width * image.height) / 1_000_000,
			maxDimension: max(image.width, image.height),
			medianTextHeight: percentile(0.5, values: heights),
			p25TextHeight: percentile(0.25, values: heights)
		)
	}

	private static func shouldSplitPartitionImage(width: Int, height: Int) -> Bool {
		let megapixels = Double(width * height) / 1_000_000
		let maxDimension = max(width, height)
		return megapixels >= minPartitionMegapixels || maxDimension >= minPartitionMaxDimension
	}

	private static func percentile(_ percentile: Double, values: [Double]) -> Double? {
		guard !values.isEmpty else { return nil }
		let index = Int((Double(values.count - 1) * percentile).rounded(.down))
		return values[min(max(index, 0), values.count - 1)]
	}

	private static func split(_ partition: Partition, image: CGImage) -> [Partition] {
		let partitionWidth = partition.box.width * Double(image.width)
		let partitionHeight = partition.box.height * Double(image.height)
		let depth = partition.depth + 1
		if partitionWidth >= partitionHeight {
			return [
				Partition(
					box: BoundingBox(x: partition.box.x, y: partition.box.y, width: partition.box.width * 0.55, height: partition.box.height),
					depth: depth
				),
				Partition(
					box: BoundingBox(
						x: partition.box.x + partition.box.width * 0.45,
						y: partition.box.y,
						width: partition.box.width * 0.55,
						height: partition.box.height
					),
					depth: depth
				),
			]
		}
		return [
			Partition(
				box: BoundingBox(x: partition.box.x, y: partition.box.y, width: partition.box.width, height: partition.box.height * 0.55),
				depth: depth
			),
			Partition(
				box: BoundingBox(
					x: partition.box.x,
					y: partition.box.y + partition.box.height * 0.45,
					width: partition.box.width,
					height: partition.box.height * 0.55
				),
				depth: depth
			),
		]
	}

	private static func shouldSplitPartition(_ result: OCRResult, image: CGImage, options: OCROptions) -> Bool {
		guard shouldSplitPartitionImage(width: image.width, height: image.height) else { return false }
		guard !result.observations.isEmpty else { return true }
		let heights = result.observations.map(\.boundingBox.height).sorted()
		if let p25 = percentile(0.25, values: heights), p25 < smallTextP25Threshold { return true }
		if let median = percentile(0.5, values: heights), median < smallTextMedianThreshold { return true }
		return false
	}

	private static func withSource(_ source: ObservationSource, result: OCRResult) -> OCRResult {
		let observations = result.observations.map { observation in
			Observation(
				text: observation.text,
				confidence: observation.confidence,
				requestRevision: observation.requestRevision,
				boundingBox: observation.boundingBox,
				candidates: observation.candidates,
				words: observation.words,
				source: source
			)
		}
		return OCRResult(text: observations.map(\.text).joined(separator: "\n"), observations: observations)
	}

	private static func remap(_ observation: Observation, from partition: Partition) -> Observation {
		let box = remap(observation.boundingBox, from: partition.box)
		let words = observation.words.map { word in
			WordBox(text: word.text, boundingBox: remap(word.boundingBox, from: partition.box))
		}
		let edgeTouching = touchesInternalEdge(observation.boundingBox, partition: partition.box)
		return Observation(
			text: observation.text,
			confidence: observation.confidence,
			requestRevision: observation.requestRevision,
			boundingBox: box,
			candidates: observation.candidates,
			words: words,
			source: ObservationSource(pass: "partition", partition: partition.box, edgeTouching: edgeTouching, depth: partition.depth)
		)
	}

	private static func remap(_ box: BoundingBox, from tile: BoundingBox) -> BoundingBox {
		BoundingBox(
			x: tile.x + box.x * tile.width,
			y: tile.y + box.y * tile.height,
			width: box.width * tile.width,
			height: box.height * tile.height
		)
	}

	private static func touchesInternalEdge(_ box: BoundingBox, partition: BoundingBox) -> Bool {
		let threshold = 0.02
		let pageThreshold = 0.0001
		let touchesLeft = box.x <= threshold && partition.x > pageThreshold
		let touchesTop = box.y <= threshold && partition.y > pageThreshold
		let touchesRight = box.x + box.width >= 1 - threshold && partition.x + partition.width < 1 - pageThreshold
		let touchesBottom = box.y + box.height >= 1 - threshold && partition.y + partition.height < 1 - pageThreshold
		return touchesLeft || touchesTop || touchesRight || touchesBottom
	}

	private static func merge(
		_ observation: DebugOCRObservation,
		into observations: inout [DebugOCRObservation]
	) -> DebugMergeRejection? {
		guard let index = observations.firstIndex(where: { isDuplicate($0.observation, observation.observation) }) else {
			observations.append(observation)
			return nil
		}
		let existing = observations[index]
		let existingText = existing.observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
		let newText = observation.observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
		if existingText.contains(newText), existingText.count > newText.count {
			return DebugMergeRejection(
				observation: observation,
				rejection: dedupeRejection(
					reason: "contained",
					rejected: observation,
					kept: existing
				)
			)
		}
		if newText.contains(existingText), newText.count > existingText.count {
			observations[index] = observation
			return DebugMergeRejection(
				observation: existing,
				rejection: dedupeRejection(
					reason: "contained",
					rejected: existing,
					kept: observation
				)
			)
		}
		if score(observation.observation) > score(existing.observation) {
			observations[index] = observation
			return DebugMergeRejection(
				observation: existing,
				rejection: dedupeRejection(
					reason: "duplicate",
					rejected: existing,
					kept: observation
				)
			)
		}
		return DebugMergeRejection(
			observation: observation,
			rejection: dedupeRejection(
				reason: "duplicate",
				rejected: observation,
				kept: existing
			)
		)
	}

	private static func partitionRejection(for observation: Observation, options: OCROptions) -> DebugRejection? {
		guard observation.source?.pass == "partition" else { return nil }
		let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard text.count >= minPartitionTextLength else {
			return DebugRejection(
				reason: "too-short",
				supersededBy: nil,
				detail: DebugRejectionDetail(
					textLength: text.count,
					minimumTextLength: minPartitionTextLength
				)
			)
		}
		guard observation.source?.edgeTouching != true else {
			return DebugRejection(reason: "internal-edge", supersededBy: nil, detail: nil)
		}
		if let minimumTextHeight = options.minimumTextHeight,
			observation.boundingBox.height < Double(minimumTextHeight)
		{
			return DebugRejection(
				reason: "below-min-text-height",
				supersededBy: nil,
				detail: DebugRejectionDetail(
					textHeight: observation.boundingBox.height,
					minimumTextHeight: minimumTextHeight
				)
			)
		}
		guard observation.confidence >= minPartitionConfidence else {
			return DebugRejection(
				reason: "low-confidence",
				supersededBy: nil,
				detail: DebugRejectionDetail(
					confidence: observation.confidence,
					minimumConfidence: minPartitionConfidence
				)
			)
		}
		return nil
	}

	private static func dedupeRejection(
		reason: String,
		rejected: DebugOCRObservation,
		kept: DebugOCRObservation
	) -> DebugRejection {
		DebugRejection(
			reason: reason,
			supersededBy: kept.id,
			detail: DebugRejectionDetail(
				iou: intersectionOverUnion(rejected.observation.boundingBox, kept.observation.boundingBox),
				intersectionOverSmallerArea: intersectionOverSmallerArea(
					rejected.observation.boundingBox,
					kept.observation.boundingBox
				),
				rejectedScore: score(rejected.observation),
				keptScore: score(kept.observation)
			)
		)
	}

	private static func isDuplicate(_ lhs: Observation, _ rhs: Observation) -> Bool {
		let lhsText = lhs.text.trimmingCharacters(in: .whitespacesAndNewlines)
		let rhsText = rhs.text.trimmingCharacters(in: .whitespacesAndNewlines)
		let textOverlaps = lhsText == rhsText || lhsText.contains(rhsText) || rhsText.contains(lhsText)
		guard textOverlaps else { return false }
		if intersectionOverUnion(lhs.boundingBox, rhs.boundingBox) >= 0.5 { return true }
		return intersectionOverSmallerArea(lhs.boundingBox, rhs.boundingBox) >= 0.6
	}

	private static func score(_ observation: Observation) -> Double {
		var score = Double(observation.confidence)
		if observation.source?.pass == "full" { score += 0.05 }
		if observation.source?.edgeTouching == true { score -= 0.15 } else { score += 0.05 }
		return score
	}

	private static func intersectionOverUnion(_ lhs: BoundingBox, _ rhs: BoundingBox) -> Double {
		let intersection = intersectionArea(lhs, rhs)
		guard intersection > 0 else { return 0 }
		let union = lhs.width * lhs.height + rhs.width * rhs.height - intersection
		return union > 0 ? intersection / union : 0
	}

	private static func intersectionOverSmallerArea(_ lhs: BoundingBox, _ rhs: BoundingBox) -> Double {
		let intersection = intersectionArea(lhs, rhs)
		guard intersection > 0 else { return 0 }
		let smallerArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
		return smallerArea > 0 ? intersection / smallerArea : 0
	}

	private static func intersectionArea(_ lhs: BoundingBox, _ rhs: BoundingBox) -> Double {
		let lhsMaxX = lhs.x + lhs.width
		let lhsMaxY = lhs.y + lhs.height
		let rhsMaxX = rhs.x + rhs.width
		let rhsMaxY = rhs.y + rhs.height
		let intersectionWidth = max(0, min(lhsMaxX, rhsMaxX) - max(lhs.x, rhs.x))
		let intersectionHeight = max(0, min(lhsMaxY, rhsMaxY) - max(lhs.y, rhs.y))
		return intersectionWidth * intersectionHeight
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
		debugOverlay: Bool = false,
		debugObservations: [DebugOCRObservation] = [],
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

		if debugOverlay {
			drawDebugOverlay(
				ocr: ocr,
				debugObservations: debugObservations,
				mediaBox: mediaBox,
				into: context
			)
		}

		context.endPDFPage()
	}

	private static func drawDebugOverlay(
		ocr: OCRResult,
		debugObservations: [DebugOCRObservation],
		mediaBox: CGRect,
		into context: CGContext
	) {
		context.saveGState()
		context.setLineWidth(max(min(mediaBox.width, mediaBox.height) * 0.001, 0.5))
		context.setStrokeColor(red: 1, green: 0, blue: 0, alpha: 0.85)
		for observation in ocr.observations {
			context.stroke(pdfRect(normalizedBox: observation.boundingBox, mediaBox: mediaBox))
		}
		context.setStrokeColor(red: 0, green: 0.25, blue: 1, alpha: 0.85)
		for observation in ocr.observations {
			for word in observation.words {
				context.stroke(pdfRect(normalizedBox: word.boundingBox, mediaBox: mediaBox))
			}
		}
		context.setStrokeColor(red: 1, green: 0.55, blue: 0, alpha: 0.85)
		for observation in debugObservations where !observation.status.isAccepted {
			context.stroke(pdfRect(normalizedBox: observation.observation.boundingBox, mediaBox: mediaBox))
		}
		context.restoreGState()
	}

	private static func pdfRect(normalizedBox box: BoundingBox, mediaBox: CGRect) -> CGRect {
		CGRect(
			x: mediaBox.minX + CGFloat(box.x) * mediaBox.width,
			y: mediaBox.minY + CGFloat(1 - box.y - box.height) * mediaBox.height,
			width: CGFloat(box.width) * mediaBox.width,
			height: CGFloat(box.height) * mediaBox.height
		)
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
