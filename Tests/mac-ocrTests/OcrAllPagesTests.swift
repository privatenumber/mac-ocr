import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import MacOcrCore

/// Behavior of the born-digital skip and its `--ocr-all-pages` override on
/// hybrid pages — a scanned (raster) body plus a small digital text element
/// (Bates stamp, fax header, binder page number). The page-level "has any text
/// operator" detection classifies such pages as born-digital, so by default
/// the scanned body gets no OCR layer; `ocrAllPages` forces recognition.
@Suite(.serialized) struct OcrAllPagesTests {

	@Test func hybridPageIsSkippedByDefault() async throws {
		// Characterizes the documented limitation: one digital stamp makes the
		// whole page count as born-digital, so the raster text stays
		// unsearchable.
		let path = try writeTemporaryPDF(makeHybridPagePDF(), label: "hybrid-default")
		defer { try? FileManager.default.removeItem(atPath: path) }

		let output = try await VisionGate.shared.withPermit {
			try await SearchablePDF.render(source: .file(path), options: OCROptions(), pdfDpi: nil)
		}
		let text = try extractText(output)
		#expect(text.contains("STAMP-7"), "the digital stamp must survive: \(text)")
		#expect(
			!text.contains("Hello"),
			"default render must not OCR a page that already draws text; got: \(text)"
		)
	}

	@Test func ocrAllPagesRecognizesTheRasterBody() async throws {
		let path = try writeTemporaryPDF(makeHybridPagePDF(), label: "hybrid-forced")
		defer { try? FileManager.default.removeItem(atPath: path) }

		let output = try await VisionGate.shared.withPermit {
			try await SearchablePDF.render(
				source: .file(path), options: OCROptions(), pdfDpi: nil, ocrAllPages: true
			)
		}
		let text = try extractText(output)
		#expect(
			text.contains("Hello World"),
			"--ocr-all-pages must add a text layer for the scanned body; got: \(text)"
		)
		// The stamp may now legitimately appear twice (original + recognized
		// overlay) — that duplication is the documented cost of the flag.
		#expect(text.contains("STAMP-7"))
	}

	@Test func ocrAllPagesLeavesBornDigitalDuplicationToTheCaller() async throws {
		// Sanity: with the flag ON, a fully born-digital page gets a duplicate
		// layer — the flag is a sharp tool by design, not a smarter detector.
		let path = try writeTemporaryPDF(makeBornDigitalPDF("Quartz"), label: "born-forced")
		defer { try? FileManager.default.removeItem(atPath: path) }

		let output = try await VisionGate.shared.withPermit {
			try await SearchablePDF.render(
				source: .file(path), options: OCROptions(), pdfDpi: nil, ocrAllPages: true
			)
		}
		let text = try extractText(output)
		let occurrences = text.components(separatedBy: "Quartz").count - 1
		#expect(occurrences >= 1, "original text must survive; got: \(text)")
	}

	@Test func formXObjectTextIsNotDetectedAsBornDigital() async throws {
		// Characterizes the second documented limitation: the detector scans
		// only the page's own content stream, so born-digital text hidden in a
		// Form XObject is invisible to it — the page gets OCR'd and the text
		// is duplicated (original + invisible overlay).
		let path = try writeTemporaryPDF(makeFormXObjectTextPDF(), label: "form-xobject")
		defer { try? FileManager.default.removeItem(atPath: path) }

		let output = try await VisionGate.shared.withPermit {
			try await SearchablePDF.render(source: .file(path), options: OCROptions(), pdfDpi: nil)
		}
		let text = try extractText(output)
		let occurrences = text.components(separatedBy: "Hello World").count - 1
		#expect(
			occurrences == 2,
			"expected the Form-XObject text duplicated by the OCR overlay (the documented limitation); got \(occurrences) in: \(text)"
		)
	}

	// MARK: - Helpers

	private func writeTemporaryPDF(_ data: Data, label: String) throws -> String {
		let path = NSTemporaryDirectory() + "mac-ocr-allpages-\(label)-\(UUID().uuidString).pdf"
		try data.write(to: URL(fileURLWithPath: path))
		return path
	}

	private func extractText(_ pdfData: Data) throws -> String {
		let document = try #require(PDFDocument(data: pdfData))
		return document.string ?? ""
	}

	private func drawText(_ string: String, at point: CGPoint, fontSize: CGFloat, in context: CGContext) {
		let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
		let attributes: [NSAttributedString.Key: Any] = [
			NSAttributedString.Key(kCTFontAttributeName as String): font
		]
		let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
		context.textPosition = point
		CTLineDraw(line, context)
	}

	/// A raster of "Hello World" — black 40pt text on white, 400×100, the same
	/// recipe as the proven `hello.png` fixture.
	private func makeTextRaster() -> CGImage {
		let width = 400
		let height = 100
		let context = CGContext(
			data: nil, width: width, height: height,
			bitsPerComponent: 8, bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		)!
		context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		drawText("Hello World", at: CGPoint(x: 30, y: 35), fontSize: 40, in: context)
		return context.makeImage()!
	}

	/// Hybrid page: the raster body (no text operators — just an image) plus
	/// one small digital text run, like a Bates stamp.
	private func makeHybridPagePDF() -> Data {
		let data = NSMutableData()
		let consumer = CGDataConsumer(data: data as CFMutableData)!
		var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 200)
		let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
		context.beginPDFPage(nil)
		context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		context.fill(mediaBox)
		context.draw(makeTextRaster(), in: CGRect(x: 10, y: 80, width: 400, height: 100))
		context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		drawText("STAMP-7", at: CGPoint(x: 330, y: 16), fontSize: 14, in: context)
		context.endPDFPage()
		context.closePDF()
		return data as Data
	}

	/// Fully born-digital page (selectable text only).
	private func makeBornDigitalPDF(_ text: String) -> Data {
		let data = NSMutableData()
		let consumer = CGDataConsumer(data: data as CFMutableData)!
		var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 120)
		let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
		context.beginPDFPage(nil)
		context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		context.fill(mediaBox)
		context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		drawText(text, at: CGPoint(x: 20, y: 45), fontSize: 42, in: context)
		context.endPDFPage()
		context.closePDF()
		return data as Data
	}

	/// Hand-built page whose only text lives inside a Form XObject — the page
	/// content stream is just `/Fm0 Do`, so the content-stream text scan sees
	/// no text operators. Helvetica is a base-14 font; no embedding needed.
	private func makeFormXObjectTextPDF() -> Data {
		let formStream = "BT /F1 40 Tf 30 40 Td (Hello World) Tj ET"
		let pageStream = "q /Fm0 Do Q"

		var content = Data("%PDF-1.4\n".utf8)
		var offsets: [Int] = []

		func appendObject(_ body: String) {
			offsets.append(content.count)
			content.append(contentsOf: body.utf8)
		}

		appendObject("1 0 obj\n<</Type /Catalog /Pages 2 0 R>>\nendobj\n")
		appendObject("2 0 obj\n<</Type /Pages /Kids [3 0 R] /Count 1>>\nendobj\n")
		appendObject(
			"3 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [0 0 300 120] /Contents 4 0 R "
				+ "/Resources <</XObject <</Fm0 5 0 R>>>>>>\nendobj\n"
		)
		appendObject("4 0 obj\n<</Length \(pageStream.utf8.count)>>\nstream\n\(pageStream)\nendstream\nendobj\n")
		appendObject(
			"5 0 obj\n<</Type /XObject /Subtype /Form /BBox [0 0 300 120] "
				+ "/Resources <</Font <</F1 6 0 R>>>> /Length \(formStream.utf8.count)>>\nstream\n\(formStream)\nendstream\nendobj\n"
		)
		appendObject("6 0 obj\n<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>\nendobj\n")

		let xrefOffset = content.count
		content.append(contentsOf: "xref\n0 \(offsets.count + 1)\n0000000000 65535 f\r\n".utf8)
		for offset in offsets {
			content.append(contentsOf: String(format: "%010d 00000 n\r\n", offset).utf8)
		}
		content.append(
			contentsOf: "trailer\n<</Size \(offsets.count + 1) /Root 1 0 R>>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8
		)
		return content
	}
}
