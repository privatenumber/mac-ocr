import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import MacOcrCore

/// Fidelity of PDF rendering: OCR must see only the visible (cropped) page, and
/// searchable-pdf output must preserve source geometry (rotation/crop).
@Suite(.serialized) struct PDFFidelityTests {

	// MARK: - [P1] CropBox clipping (OCR)

	@Test func cropBoxClipsOcrToVisibleRegion() throws {
		// MediaBox is 400×200; CropBox shows only the left 200×200. "INSIDE" is
		// in the crop region; "OUTSIDE" is in the media box but cropped away.
		let pdf = makeCropBoxPDF()
		let path = temporaryPDFPath("crop")
		defer { try? FileManager.default.removeItem(atPath: path) }
		try pdf.write(to: URL(fileURLWithPath: path))

		let result = try TestSupport.run(["ocr", path])
		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		#expect(result.stdout.contains("INSIDE"), "expected visible text; got: \(result.stdout)")
		#expect(
			!result.stdout.contains("OUTSIDE"),
			"OCR leaked cropped-away text outside the CropBox; got: \(result.stdout)"
		)
	}

	// MARK: - [P2] Preserve source geometry (rotation) in searchable-pdf output

	@Test func rotatedPagePreservesDisplayedGeometry() async throws {
		// A 400×100 page with /Rotate 90 displays as 100×400.
		let pdf = buildRotatedRectPDF(width: 400, height: 100, rotate: 90)
		let path = temporaryPDFPath("rotate")
		defer { try? FileManager.default.removeItem(atPath: path) }
		try pdf.write(to: URL(fileURLWithPath: path))

		let output = temporaryPDFPath("rotate-output")
		defer { try? FileManager.default.removeItem(atPath: output) }
		try await VisionGate.shared.withPermit {
			try await SearchablePDF.write(source: .file(path), to: URL(fileURLWithPath: output), options: OCROptions(), pdfDpi: nil)
		}
		let document = try #require(PDFDocument(url: URL(fileURLWithPath: output)))
		let bounds = try #require(document.page(at: 0)).bounds(for: .mediaBox)
		#expect(
			Int(bounds.width) == 100 && Int(bounds.height) == 400,
			"expected 100×400 displayed page (rotation preserved); got \(Int(bounds.width))×\(Int(bounds.height))"
		)
	}

	@Test func ordinaryFileOutputPreservesScannedPagesAndInput() throws {
		let input = TestSupport.fixturePath("multipage.pdf")
		let original = try Data(contentsOf: URL(fileURLWithPath: input))
		let output = temporaryPDFPath("scanned-file-output")
		defer { try? FileManager.default.removeItem(atPath: output) }
		let result = try TestSupport.run(["searchable-pdf", input, "-o", output, "--ocr-strategy", "standard", "--pdf-dpi", "144"])
		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		#expect(try Data(contentsOf: URL(fileURLWithPath: input)) == original)
		let source = try #require(PDFDocument(data: original))
		let document = try #require(PDFDocument(url: URL(fileURLWithPath: output)))
		#expect(document.pageCount == 3)
		for (index, text) in ["Page One", "Page Two", "Page Three"].enumerated() {
			let before = try #require(source.page(at: index))
			let after = try #require(document.page(at: index))
			#expect(after.string?.contains(text) == true)
			#expect(after.bounds(for: .mediaBox) == before.bounds(for: .mediaBox))
			#expect(try pixels(after) == pixels(before), "appearance changed on page \(index + 1)")
		}
	}

	private func pixels(_ page: PDFPage) throws -> Data {
		let bounds = page.bounds(for: .cropBox)
		let width = Int(bounds.width)
		let height = Int(bounds.height)
		let context = try #require(
			CGContext(
				data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
				space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			))
		context.setFillColor(CGColor(gray: 1, alpha: 1))
		context.fill(CGRect(x: 0, y: 0, width: width, height: height))
		page.draw(with: .cropBox, to: context)
		return Data(bytes: try #require(context.data), count: width * height * 4)
	}

	// MARK: - Fixture helpers

	private func temporaryPDFPath(_ label: String) -> String {
		NSTemporaryDirectory() + "mac-ocr-fidelity-\(label)-\(UUID().uuidString).pdf"
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

	/// 400×200 page with a 200×200 CropBox (left half). "INSIDE" sits in the
	/// crop region; "OUTSIDE" is to its right, inside the media box but clipped.
	private func makeCropBoxPDF() -> Data {
		let data = NSMutableData()
		let consumer = CGDataConsumer(data: data as CFMutableData)!
		var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 200)
		let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
		var cropBox = CGRect(x: 0, y: 0, width: 200, height: 200)
		let cropData = withUnsafeBytes(of: &cropBox) { Data($0) }
		context.beginPDFPage([kCGPDFContextCropBox: cropData] as CFDictionary)
		context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
		drawText("INSIDE", at: CGPoint(x: 16, y: 90), fontSize: 40, in: context)
		drawText("OUTSIDE", at: CGPoint(x: 212, y: 90), fontSize: 40, in: context)
		context.endPDFPage()
		context.closePDF()
		return data as Data
	}

	/// Hand-built 1-page PDF with an explicit /Rotate and a filled-rectangle
	/// content stream. `CGContext` PDF generation can't emit /Rotate, so this is
	/// assembled by hand.
	private func buildRotatedRectPDF(width: Int, height: Int, rotate: Int) -> Data {
		let stream = "1 0 0 rg\n0 0 \(width) \(height) re\nf"
		let streamBytes = Array(stream.utf8)

		var content = Data("%PDF-1.4\n".utf8)
		var offsets: [Int] = []

		offsets.append(content.count)
		content.append(contentsOf: "1 0 obj\n<</Type /Catalog /Pages 2 0 R>>\nendobj\n".utf8)

		offsets.append(content.count)
		content.append(contentsOf: "2 0 obj\n<</Type /Pages /Kids [3 0 R] /Count 1>>\nendobj\n".utf8)

		offsets.append(content.count)
		content.append(
			contentsOf: "3 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] /Rotate \(rotate) /Contents 4 0 R /Resources <<>>>>\nendobj\n"
				.utf8)

		offsets.append(content.count)
		content.append(contentsOf: "4 0 obj\n<</Length \(streamBytes.count)>>\nstream\n".utf8)
		content.append(contentsOf: streamBytes)
		content.append(contentsOf: "\nendstream\nendobj\n".utf8)

		let xrefOffset = content.count
		content.append(contentsOf: "xref\n0 5\n0000000000 65535 f\r\n".utf8)
		for offset in offsets {
			content.append(contentsOf: String(format: "%010d 00000 n\r\n", offset).utf8)
		}
		content.append(contentsOf: "trailer\n<</Size 5 /Root 1 0 R>>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)

		return content
	}
}
