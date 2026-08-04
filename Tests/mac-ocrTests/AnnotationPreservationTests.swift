import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import MacOcrCore

/// The verbatim pass-through: when every page already has selectable text and
/// `--ocr-all-pages` is off, `searchable-pdf` must return the input bytes
/// untouched — a rewrite would silently drop annotations (links, form
/// fields), outlines, and metadata. Regression for the finding that a
/// born-digital IRS form lost all 199 of its field annotations.
@Suite(.serialized) struct AnnotationPreservationTests {

	@Test func bornDigitalPdfPassesThroughByteIdentical() async throws {
		let input = try makeAnnotatedBornDigitalPDF()
		let path = try write(input, label: "annotated")
		defer { try? FileManager.default.removeItem(atPath: path) }

		let output = try await VisionGate.shared.withPermit {
			try await SearchablePDF.render(source: .file(path), options: OCROptions(), pdfDpi: nil)
		}

		#expect(output == input, "nothing needed OCR — output must be the input bytes, verbatim")
		let document = try #require(PDFDocument(data: output))
		let annotations = (0..<document.pageCount).reduce(0) { $0 + (document.page(at: $1)?.annotations.count ?? 0) }
		#expect(annotations == 1, "the link annotation must survive")
	}

	@Test func ocrAllPagesStillRewrites() async throws {
		// The flag forces recognition, which takes the rewrite path — output
		// differs and (documented limitation) annotations do not survive it.
		let input = try makeAnnotatedBornDigitalPDF()
		let path = try write(input, label: "annotated-forced")
		defer { try? FileManager.default.removeItem(atPath: path) }

		let output = try await VisionGate.shared.withPermit {
			try await SearchablePDF.render(
				source: .file(path), options: OCROptions(), pdfDpi: nil, ocrAllPages: true
			)
		}

		#expect(output != input)
		let document = try #require(PDFDocument(data: output))
		#expect((document.string ?? "").contains("Quartz"), "original text must survive the rewrite")
	}

	@Test func mixedDocumentTakesTheRewritePath() async throws {
		// One scanned page forces the rewrite for the whole document (the
		// pass-through is all-or-nothing) — and the scanned page gains a layer.
		let input = try makeMixedPDF()
		let path = try write(input, label: "mixed")
		defer { try? FileManager.default.removeItem(atPath: path) }

		let output = try await VisionGate.shared.withPermit {
			try await SearchablePDF.render(source: .file(path), options: OCROptions(), pdfDpi: nil)
		}

		#expect(output != input)
		let document = try #require(PDFDocument(data: output))
		let text = document.string ?? ""
		#expect(text.contains("Quartz"), "born-digital page text must survive")
		#expect(text.contains("Hello World"), "scanned page must gain an OCR layer")
	}

	// MARK: - Fixtures

	private func write(_ data: Data, label: String) throws -> String {
		let path = NSTemporaryDirectory() + "mac-ocr-annot-\(label)-\(UUID().uuidString).pdf"
		try data.write(to: URL(fileURLWithPath: path))
		return path
	}

	private func drawText(_ string: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
		let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
		let attributes: [NSAttributedString.Key: Any] = [
			NSAttributedString.Key(kCTFontAttributeName as String): font
		]
		let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
		context.textPosition = point
		CTLineDraw(line, context)
	}

	/// Born-digital page with selectable text plus one link annotation
	/// (added via PDFKit, like real-world tooling would).
	private func makeAnnotatedBornDigitalPDF() throws -> Data {
		let raw = NSMutableData()
		var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 120)
		let context = CGContext(consumer: CGDataConsumer(data: raw as CFMutableData)!, mediaBox: &mediaBox, nil)!
		context.beginPDFPage(nil)
		context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		context.fill(mediaBox)
		context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		drawText("Quartz", at: CGPoint(x: 20, y: 45), size: 42, in: context)
		context.endPDFPage()
		context.closePDF()

		let document = try #require(PDFDocument(data: raw as Data))
		let page = try #require(document.page(at: 0))
		let annotation = PDFAnnotation(
			bounds: CGRect(x: 20, y: 40, width: 160, height: 50), forType: .link, withProperties: nil)
		annotation.url = URL(string: "https://example.com")
		page.addAnnotation(annotation)
		return try #require(document.dataRepresentation())
	}

	/// Page 1 born-digital ("Quartz"), page 2 a raster of "Hello World"
	/// (no text operators — a scan).
	private func makeMixedPDF() throws -> Data {
		let image = makeTextRaster()
		let raw = NSMutableData()
		var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 120)
		let context = CGContext(consumer: CGDataConsumer(data: raw as CFMutableData)!, mediaBox: &mediaBox, nil)!

		context.beginPDFPage(nil)
		context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		context.fill(mediaBox)
		context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		drawText("Quartz", at: CGPoint(x: 20, y: 45), size: 42, in: context)
		context.endPDFPage()

		context.beginPDFPage(nil)
		context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		context.fill(mediaBox)
		context.draw(image, in: CGRect(x: 10, y: 10, width: 400, height: 100))
		context.endPDFPage()

		context.closePDF()
		return raw as Data
	}

	private func makeTextRaster() -> CGImage {
		let context = CGContext(
			data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		)!
		context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
		context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		drawText("Hello World", at: CGPoint(x: 30, y: 35), size: 40, in: context)
		return context.makeImage()!
	}
}
