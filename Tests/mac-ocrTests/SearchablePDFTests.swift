import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing

@testable import MacOcrCore

@Suite(.serialized) struct SearchablePDFTests {
	private static let fixtures = EngineTestSupport.fixturesURL

	private static func source(_ name: String) -> ImageSource {
		.file(fixtures.appendingPathComponent(name).path)
	}

	private func render(
		_ name: String,
		pdfDpi: Int? = nil,
		imageQuality: Double? = nil,
		imagePageDpi: Double? = nil,
		imageDownsampleDpi: Double? = nil
	) async throws -> PDFDocument {
		let data = try await VisionGate.shared.withPermit {
			try await SearchablePDF.render(
				source: Self.source(name),
				options: OCROptions(),
				pdfDpi: pdfDpi,
				imageQuality: imageQuality,
				imagePageDpi: imagePageDpi,
				imageDownsampleDpi: imageDownsampleDpi
			)
		}
		guard let document = PDFDocument(data: data) else {
			throw MessageError("output was not a valid PDF")
		}
		return document
	}

	private func text(_ document: PDFDocument) -> String {
		(document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
	}

	@Test func imageBecomesOnePageWithSelectableText() async throws {
		let document = try await render("hello.png")
		#expect(document.pageCount == 1)
		#expect(text(document).contains("Hello World"))
	}

	@Test func pdfPagesStayInOrder() async throws {
		// Each scanned page's recognized text must land on its own page, in
		// order. Guards the render/OCR pipeline against shuffling pages when
		// rendering runs ahead of recognition on a background task.
		let document = try await render("multipage.pdf")
		#expect(document.pageCount == 3)
		let perPage = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
		#expect(perPage[0].contains("Page One"))
		#expect(perPage[1].contains("Page Two"))
		#expect(perPage[2].contains("Page Three"))
	}

	@Test func recognizedWordsExtractAsCleanRuns() async throws {
		// Regression: a non-unit horizontal text scale once made extractors read
		// "Hello" as "H e l l o", breaking search. Assert contiguous words survive.
		let document = try await render("document-photo.png")
		#expect(text(document).contains("Hello World"))
	}

	@Test func invisibleTextIsPositionedPerWord() async throws {
		// The invisible layer draws one run per word at Vision's per-word box,
		// so selecting "World" must land to the right of "Hello" rather than
		// both starting at the line origin (the old line-level behavior).
		let document = try await render("hello.png")
		let page = try #require(document.page(at: 0))

		func selectionBounds(_ word: String) throws -> CGRect {
			let selections = document.findString(word, withOptions: [])
			let selection = try #require(selections.first, "expected '\(word)' to be findable")
			return selection.bounds(for: page)
		}

		let hello = try selectionBounds("Hello")
		let world = try selectionBounds("World")
		#expect(
			world.minX > hello.minX + hello.width * 0.5,
			"'World' selection must start past 'Hello' (per-word geometry); hello: \(hello), world: \(world)"
		)
		// Each word's run is narrower than the whole line.
		let line = hello.union(world)
		#expect(hello.width < line.width)
		#expect(world.width < line.width)
	}

	@Test func emptyImageProducesPageWithoutText() async throws {
		let document = try await render("empty.png")
		#expect(document.pageCount == 1)
		#expect(text(document).isEmpty)
	}

	@Test func imageWithoutDocumentDPIUsesPixelDimensions() async throws {
		// The default 72 DPI fallback preserves 1px = 1pt sizing.
		let document = try await render("hello.png")
		let bounds = try #require(document.page(at: 0)).bounds(for: .mediaBox)
		#expect(Int(bounds.width) == 400)
		#expect(Int(bounds.height) == 100)
	}

	@Test func imagePageUsesEmbeddedDPI() async throws {
		let directory = try InputMatrixSupport.makeTempDir("spdf-dpi")
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let path = directory + "/hello-400dpi.jpg"
		try writeDPIImage(InputMatrixSupport.makeHelloRaster(), to: path, dpi: 400)

		let document = try await VisionGate.shared.withPermit {
			try await SearchablePDF.render(
				source: .file(path),
				options: OCROptions(),
				pdfDpi: nil
			)
		}
		let page = try #require(PDFDocument(data: document)?.page(at: 0))
		let bounds = page.bounds(for: .mediaBox)
		#expect(abs(bounds.width - 72) < 0.1)
		#expect(abs(bounds.height - 18) < 0.1)
	}
	@Test func imagePageDPIOverridesEmbeddedDPI() async throws {
		let directory = try InputMatrixSupport.makeTempDir("spdf-dpi-override")
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let path = directory + "/hello-400dpi.jpg"
		try writeDPIImage(InputMatrixSupport.makeHelloRaster(), to: path, dpi: 400)

		let data = try await VisionGate.shared.withPermit {
			try await SearchablePDF.render(
				source: .file(path),
				options: OCROptions(),
				pdfDpi: nil,
				imagePageDpi: 200
			)
		}
		let page = try #require(PDFDocument(data: data)?.page(at: 0))
		let bounds = page.bounds(for: .mediaBox)
		#expect(abs(bounds.width - 144) < 0.1)
		#expect(abs(bounds.height - 36) < 0.1)
	}

	@Test func imageQualityKeepsSearchableTextAndPageSize() async throws {
		let document = try await render("hello.png", imageQuality: 0.6)
		#expect(document.pageCount == 1)
		#expect(text(document).contains("Hello World"))
		let bounds = try #require(document.page(at: 0)).bounds(for: .mediaBox)
		#expect(Int(bounds.width) == 400)
		#expect(Int(bounds.height) == 100)
	}

	@Test func imageQualityAvoidsRawBitmapSizedOutput() async throws {
		let directory = try InputMatrixSupport.makeTempDir("spdf-quality")
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let path = directory + "/noisy.jpg"
		let image = makeNoisyImage(width: 800, height: 600)
		try InputMatrixSupport.write(image, to: path, type: .jpeg)

		let (highQuality, lowQuality) = try await VisionGate.shared.withPermit {
			let highQuality = try await SearchablePDF.render(
				source: .file(path),
				options: OCROptions(),
				pdfDpi: nil,
				imageQuality: 0.9
			)
			let lowQuality = try await SearchablePDF.render(
				source: .file(path),
				options: OCROptions(),
				pdfDpi: nil,
				imageQuality: 0.25
			)
			return (highQuality, lowQuality)
		}

		let rawRGBBytes = image.width * image.height * 3
		#expect(
			highQuality.count < rawRGBBytes / 2,
			"expected compressed image PDF to be far smaller than raw RGB (\(highQuality.count) vs \(rawRGBBytes))"
		)
		#expect(
			lowQuality.count < highQuality.count,
			"expected lower image quality to reduce output size (\(lowQuality.count) vs \(highQuality.count))"
		)
	}

	@Test func imageDownsampleDPIReducesOutputWithoutChangingPageSize() async throws {
		let directory = try InputMatrixSupport.makeTempDir("spdf-downsample")
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let path = directory + "/noisy-400dpi.jpg"
		try writeDPIImage(makeNoisyImage(width: 800, height: 600), to: path, dpiWidth: 400, dpiHeight: 400)

		let (full, downsampled) = try await VisionGate.shared.withPermit {
			let full = try await SearchablePDF.render(
				source: .file(path),
				options: OCROptions(),
				pdfDpi: nil,
				imageQuality: 0.85
			)
			let downsampled = try await SearchablePDF.render(
				source: .file(path),
				options: OCROptions(),
				pdfDpi: nil,
				imageQuality: 0.85,
				imageDownsampleDpi: 200
			)
			return (full, downsampled)
		}

		#expect(downsampled.count < full.count)
		let fullBounds = try #require(PDFDocument(data: full)?.page(at: 0)).bounds(for: .mediaBox)
		let downsampledBounds = try #require(PDFDocument(data: downsampled)?.page(at: 0)).bounds(for: .mediaBox)
		#expect(abs(fullBounds.width - downsampledBounds.width) < 0.1)
		#expect(abs(fullBounds.height - downsampledBounds.height) < 0.1)
	}

	@Test func imageDownsampleDPIHandlesDifferentHorizontalAndVerticalDPI() async throws {
		let directory = try InputMatrixSupport.makeTempDir("spdf-downsample-axis")
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let path = directory + "/noisy-72x600dpi.jpg"
		try writeDPIImage(makeNoisyImage(width: 600, height: 800), to: path, dpiWidth: 72, dpiHeight: 600)

		let (full, downsampled) = try await VisionGate.shared.withPermit {
			let full = try await SearchablePDF.render(
				source: .file(path),
				options: OCROptions(),
				pdfDpi: nil,
				imageQuality: 0.85
			)
			let downsampled = try await SearchablePDF.render(
				source: .file(path),
				options: OCROptions(),
				pdfDpi: nil,
				imageQuality: 0.85,
				imageDownsampleDpi: 150
			)
			return (full, downsampled)
		}

		#expect(
			downsampled.count < full.count,
			"vertical-only downsampling should reduce output size when only the Y axis exceeds the target DPI"
		)
		let fullBounds = try #require(PDFDocument(data: full)?.page(at: 0)).bounds(for: .mediaBox)
		let downsampledBounds = try #require(PDFDocument(data: downsampled)?.page(at: 0)).bounds(for: .mediaBox)
		#expect(abs(fullBounds.width - downsampledBounds.width) < 0.1)
		#expect(abs(fullBounds.height - downsampledBounds.height) < 0.1)
	}

	private func makeNoisyImage(width: Int, height: Int) -> CGImage {
		let bytesPerPixel = 4
		let bytesPerRow = width * bytesPerPixel
		var data = [UInt8](repeating: 255, count: height * bytesPerRow)
		for y in 0..<height {
			for x in 0..<width {
				let offset = y * bytesPerRow + x * bytesPerPixel
				let value = UInt8((x * 31 + y * 17 + (x * y) % 251) % 256)
				data[offset] = value
				data[offset + 1] = UInt8(255 - Int(value))
				data[offset + 2] = UInt8((Int(value) * 7) % 256)
			}
		}
		return data.withUnsafeMutableBytes { bytes in
			let context = CGContext(
				data: bytes.baseAddress,
				width: width,
				height: height,
				bitsPerComponent: 8,
				bytesPerRow: bytesPerRow,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
			)!
			return context.makeImage()!
		}
	}

	private func writeDPIImage(_ image: CGImage, to path: String, dpi: Double) throws {
		try writeDPIImage(image, to: path, dpiWidth: dpi, dpiHeight: dpi)
	}

	private func writeDPIImage(_ image: CGImage, to path: String, dpiWidth: Double, dpiHeight: Double) throws {
		try InputMatrixSupport.write(
			image,
			to: path,
			type: .jpeg,
			properties: [
				kCGImagePropertyDPIWidth: dpiWidth,
				kCGImagePropertyDPIHeight: dpiHeight,
			]
		)
	}
}
