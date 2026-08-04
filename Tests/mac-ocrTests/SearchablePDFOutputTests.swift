import Foundation
import PDFKit
import Testing

/// Output routing for `searchable-pdf`: per-input by default with a
/// `[name].ocr.pdf` name, `-o` templates/directories, single-destination
/// (static path / stdout) restricted to one input, and stdout via `-o -`.
@Suite(.serialized) struct SearchablePDFOutputTests {

	@Test func defaultWritesOcrPdfAlongsideInput() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let input = try stage("hello.png", in: directory)

		let result = try TestSupport.run(["searchable-pdf", input])
		#expect(result.exitCode == 0, "stderr: \(result.stderr)")

		let expected = directory + "/hello.ocr.pdf"
		#expect(FileManager.default.fileExists(atPath: expected), "expected \(expected); dir: \(listing(directory))")
		let document = try #require(PDFDocument(url: URL(fileURLWithPath: expected)))
		#expect((document.string ?? "").contains("Hello World"))
	}

	@Test func multipleInputsEachGetOwnFile() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let a = try stage("hello.png", in: directory)
		let b = try stage("document-photo.png", in: directory)

		let result = try TestSupport.run(["searchable-pdf", a, b])
		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		#expect(FileManager.default.fileExists(atPath: directory + "/hello.ocr.pdf"))
		#expect(FileManager.default.fileExists(atPath: directory + "/document-photo.ocr.pdf"))
	}

	@Test func templateOutputControlsName() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let input = try stage("hello.png", in: directory)

		let result = try TestSupport.run(["searchable-pdf", input, "-o", directory + "/[name]-searchable.pdf"])
		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		#expect(FileManager.default.fileExists(atPath: directory + "/hello-searchable.pdf"))
	}

	@Test func directoryOutputUsesDefaultName() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let input = try stage("hello.png", in: directory)
		let outDir = directory + "/out/"

		let result = try TestSupport.run(["searchable-pdf", input, "-o", outDir])
		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		#expect(FileManager.default.fileExists(atPath: directory + "/out/hello.ocr.pdf"))
	}

	@Test func staticPathWithMultipleInputsErrors() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let a = try stage("hello.png", in: directory)
		let b = try stage("document-photo.png", in: directory)

		let result = try TestSupport.run(["searchable-pdf", a, b, "-o", directory + "/one.pdf"])
		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
		#expect(!FileManager.default.fileExists(atPath: directory + "/one.pdf"), "must not write a merged file")
	}

	@Test func mergeWritesSinglePDFInArgumentOrder() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let first = try stage("hello.png", in: directory)
		let second = try stage("multipage.pdf", in: directory)
		let output = directory + "/merged.pdf"

		let result = try TestSupport.run(["searchable-pdf", "--merge", "-o", output, first, second])

		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		let document = try #require(PDFDocument(url: URL(fileURLWithPath: output)))
		#expect(document.pageCount == 4)
		let perPage = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
		#expect(perPage[0].contains("Hello World"))
		#expect(perPage[1].contains("Page One"))
		#expect(perPage[2].contains("Page Two"))
		#expect(perPage[3].contains("Page Three"))
	}

	@Test func mergeStdoutAllowsMultipleInputs() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let a = try stage("hello.png", in: directory)
		let b = try stage("document-photo.png", in: directory)

		let result = try TestSupport.run(["searchable-pdf", "--merge", "-o", "-", a, b])

		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		#expect(result.stdoutData.prefix(5) == Data("%PDF-".utf8))
		let document = try #require(PDFDocument(data: result.stdoutData))
		#expect(document.pageCount == 2)
	}

	@Test func mergeRequiresOutput() throws {
		let result = try TestSupport.run(["searchable-pdf", "--merge", TestSupport.fixturePath("hello.png")])
		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
		#expect(result.stderr.contains("`--merge` requires -o <file.pdf> or -o -."))
	}

	@Test func mergeRejectsDirectoryOutput() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let result = try TestSupport.run([
			"searchable-pdf", "--merge", "-o", directory + "/", TestSupport.fixturePath("hello.png"),
		])
		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
		#expect(result.stderr.contains("`--merge` writes one PDF and does not support directory output"))
	}

	@Test func mergeRejectsTemplateOutput() throws {
		let result = try TestSupport.run([
			"searchable-pdf", "--merge", "-o", "[name].pdf", TestSupport.fixturePath("hello.png"),
		])
		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
		#expect(result.stderr.contains("`--merge` writes one PDF and does not support output templates"))
	}

	@Test func mergeRejectsStdinInput() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let output = directory + "/merged.pdf"
		let data = try Data(contentsOf: URL(fileURLWithPath: TestSupport.fixturePath("hello.png")))
		let result = try TestSupport.run(["searchable-pdf", "--merge", "-o", output, "-"], stdinData: data)
		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
		#expect(result.stderr.contains("`--merge` does not support stdin input"))
		#expect(!FileManager.default.fileExists(atPath: output))
	}

	@Test func mergeFailureDoesNotWriteOutput() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let bad = try stage("invalid.txt", in: directory)
		let good = try stage("hello.png", in: directory)
		let output = directory + "/merged.pdf"

		let result = try TestSupport.run(["searchable-pdf", "--merge", "-o", output, good, bad])

		#expect(result.exitCode != 0)
		#expect(!FileManager.default.fileExists(atPath: output))
	}

	@Test func debugMergeWritesJsonlSidecarInArgumentOrder() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let first = try stage("hello.png", in: directory)
		let second = try stage("document-photo.png", in: directory)
		let output = directory + "/merged.pdf"
		let debug = directory + "/merged.jsonl"

		let result = try TestSupport.run(
			["searchable-pdf", "--merge", "-o", output, first, second],
			environment: ["MAC_OCR_DEBUG": "1"]
		)

		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		#expect(FileManager.default.fileExists(atPath: output))
		let records = try jsonlObjects(at: debug)
		#expect(records.count == 2)
		#expect(records[0]["schema"] as? String == "mac-ocr.searchable-pdf.debug")
		#expect(records[0]["schemaVersion"] as? Int == 2)
		let firstOutput = try #require(records[0]["output"] as? [String: Any])
		let secondOutput = try #require(records[1]["output"] as? [String: Any])
		#expect(firstOutput["page"] as? Int == 1)
		#expect(secondOutput["page"] as? Int == 2)
		#expect(firstOutput["pageCount"] as? Int == 2)
		let firstSource = try #require(records[0]["source"] as? [String: Any])
		let secondSource = try #require(records[1]["source"] as? [String: Any])
		let firstInput = try #require(firstSource["input"] as? [String: Any])
		let secondInput = try #require(secondSource["input"] as? [String: Any])
		#expect((firstInput["path"] as? String)?.hasSuffix("hello.png") == true)
		#expect((secondInput["path"] as? String)?.hasSuffix("document-photo.png") == true)
		let firstOcr = try #require(records[0]["ocr"] as? [String: Any])
		let observations = try #require(firstOcr["observations"] as? [[String: Any]])
		#expect(!observations.isEmpty)
		let firstObservation = try #require(observations.first)
		#expect(firstObservation["status"] as? String == "accepted")
		#expect(firstObservation["pdfBox"] as? [String: Any] != nil)
		let origin = try #require(firstObservation["origin"] as? [String: Any])
		#expect(origin["passId"] as? String == "full")
		let words = firstObservation["words"] as? [[String: Any]]
		#expect(words?.isEmpty == false)
		let recognition = try #require(records[0]["recognition"] as? [String: Any])
		#expect(recognition["strategy"] as? String == "auto")
		let passes = try #require(recognition["passes"] as? [String: Any])
		let fullPass = try #require(passes["full"] as? [String: Any])
		let partitionedPass = try #require(passes["partitioned"] as? [String: Any])
		#expect(fullPass["type"] as? String == "full-page")
		#expect(fullPass["enabled"] as? Bool == true)
		#expect(partitionedPass["type"] as? String == "partitioned")
		#expect(partitionedPass["enabled"] as? Bool == false)
		#expect(partitionedPass["metrics"] as? [String: Any] != nil)
		#expect(partitionedPass["thresholds"] as? [String: Any] != nil)
	}

	@Test func debugPerInputBatchWritesOneSidecarPerOutputPDF() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let first = try stage("hello.png", in: directory)
		let second = try stage("document-photo.png", in: directory)

		let result = try TestSupport.run(
			["searchable-pdf", first, second],
			environment: ["MAC_OCR_DEBUG": "1"]
		)

		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		#expect(try jsonlObjects(at: directory + "/hello.ocr.jsonl").count == 1)
		#expect(try jsonlObjects(at: directory + "/document-photo.ocr.jsonl").count == 1)
	}

	@Test func debugPartitionedRecordsRejectedObservationsWithReasons() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let input = TestSupport.fixturePath("document-photo.png")
		let output = directory + "/partitioned.pdf"
		let debug = directory + "/partitioned.jsonl"

		let result = try TestSupport.run(
			["searchable-pdf", "--ocr-strategy", "partitioned", "-o", output, input],
			environment: ["MAC_OCR_DEBUG": "1"]
		)

		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		let record = try #require(try jsonlObjects(at: debug).first)
		let recognition = try #require(record["recognition"] as? [String: Any])
		#expect(recognition["effectiveStrategy"] as? String == "partitioned")
		let passes = try #require(recognition["passes"] as? [String: Any])
		let partitioned = try #require(passes["partitioned"] as? [String: Any])
		#expect(partitioned["enabled"] as? Bool == true)
		let partitions = try #require(partitioned["partitions"] as? [[String: Any]])
		#expect(partitions.contains { ($0["rejected"] as? Int ?? 0) > 0 })

		let ocr = try #require(record["ocr"] as? [String: Any])
		let observations = try #require(ocr["observations"] as? [[String: Any]])
		let rejectedObservations = observations.filter { $0["status"] as? String == "rejected" }
		#expect(!rejectedObservations.isEmpty)
		let rejected = try #require(
			rejectedObservations.first { observation in
				let origin = observation["origin"] as? [String: Any]
				return origin?["passId"] as? String == "partition"
			}
		)
		#expect(rejected["pdfBox"] == nil)
		let origin = try #require(rejected["origin"] as? [String: Any])
		#expect(origin["passId"] as? String == "partition")
		#expect(origin["partitionId"] as? String != nil)
		let rejection = try #require(rejected["rejection"] as? [String: Any])
		#expect(rejection["reason"] as? String != nil)
	}

	@Test func debugRejectsStdoutPDFOutput() throws {
		let result = try TestSupport.run(
			["searchable-pdf", "-o", "-", TestSupport.fixturePath("hello.png")],
			environment: ["MAC_OCR_DEBUG": "1"]
		)

		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
		#expect(result.stderr.contains("MAC_OCR_DEBUG=1 requires file PDF output"))
	}

	@Test func debugRejectsSidecarCollidingWithPDFOutput() throws {
		let output = "mac-ocr-debug-collision-\(UUID().uuidString)/out.JSONL"
		defer { try? FileManager.default.removeItem(atPath: (output as NSString).deletingLastPathComponent) }
		let result = try TestSupport.run(
			["searchable-pdf", "-o", output, TestSupport.fixturePath("hello.png")],
			environment: ["MAC_OCR_DEBUG": "1"]
		)

		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
		#expect(result.stderr.contains("would overwrite a PDF output"))
		#expect(!FileManager.default.fileExists(atPath: output))
	}

	@Test func debugBornDigitalPdfWritesSkippedPageRecords() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let input = directory + "/born-digital.pdf"
		let output = directory + "/multipage.ocr.pdf"
		let debug = directory + "/multipage.ocr.jsonl"
		try makeBornDigitalPDF().write(to: URL(fileURLWithPath: input))

		let result = try TestSupport.run(
			["searchable-pdf", "-o", output, input],
			environment: ["MAC_OCR_DEBUG": "1"]
		)

		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		let records = try jsonlObjects(at: debug)
		#expect(records.count == 1)
		for record in records {
			let recognition = try #require(record["recognition"] as? [String: Any])
			#expect(recognition["skipped"] as? Bool == true)
			#expect(recognition["skipReason"] as? String == "existing-text-layer")
			let passes = try #require(recognition["passes"] as? [String: Any])
			#expect(passes.isEmpty)
			let ocr = try #require(record["ocr"] as? [String: Any])
			let observations = try #require(ocr["observations"] as? [[String: Any]])
			#expect(observations.isEmpty)
			let geometry = try #require(record["geometry"] as? [String: Any])
			let pdfPage = try #require(geometry["pdfPage"] as? [String: Any])
			let mediaBox = try #require(pdfPage["mediaBox"] as? [String: Any])
			#expect(pdfPage["rotation"] as? Int == 90)
			#expect(mediaBox["x"] as? Double == 10)
			#expect(mediaBox["y"] as? Double == 20)
		}
	}

	@Test func stdoutWithMultipleInputsErrors() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let a = try stage("hello.png", in: directory)
		let b = try stage("document-photo.png", in: directory)

		let result = try TestSupport.run(["searchable-pdf", a, b, "-o", "-"])
		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
	}

	@Test func imageQualityOutsideUnitIntervalErrors() throws {
		let result = try TestSupport.run([
			"searchable-pdf",
			TestSupport.fixturePath("hello.png"),
			"--image-quality",
			"1.5",
		])
		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
		#expect(result.stderr.contains("--image-quality must be between 0.0 and 1.0"))
	}

	@Test func imagePageDPIOutsideRangeErrors() throws {
		let result = try TestSupport.run([
			"searchable-pdf",
			TestSupport.fixturePath("hello.png"),
			"--image-page-dpi",
			"0",
		])
		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
		#expect(result.stderr.contains("--image-page-dpi must be between 36 and 2400"))
	}

	@Test func imageDownsampleDPIOutsideRangeErrors() throws {
		let result = try TestSupport.run([
			"searchable-pdf",
			TestSupport.fixturePath("hello.png"),
			"--image-downsample-dpi",
			"0",
		])
		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
		#expect(result.stderr.contains("--image-downsample-dpi must be between 36 and 2400"))
	}

	@Test func partitionedOCRStrategyRejectsROI() throws {
		let result = try TestSupport.run([
			"searchable-pdf",
			"--ocr-strategy",
			"partitioned",
			"--roi",
			"0,0,1,1",
			TestSupport.fixturePath("hello.png"),
		])
		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
		#expect(result.stderr.contains("--ocr-strategy partitioned cannot be combined with --roi"))
	}

	@Test func batchContinuesAfterAFailedInput() throws {
		// Fail-soft: a bad input is reported but does not abort the batch, so a
		// good input listed *after* it is still written. Exit is non-zero.
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let bad = try stage("invalid.txt", in: directory)
		let good = try stage("hello.png", in: directory)
		let outDir = directory + "/out"
		try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

		let result = try TestSupport.run(["searchable-pdf", bad, good, "-o", outDir + "/"])

		#expect(result.exitCode == 1, "expected partial-failure exit 1; got \(result.exitCode), stderr: \(result.stderr)")
		#expect(FileManager.default.fileExists(atPath: outDir + "/hello.ocr.pdf"), "good input after a failure must still be written")
		#expect(!FileManager.default.fileExists(atPath: outDir + "/invalid.ocr.pdf"))
	}

	@Test func collidingOutputPathsErrorBeforeWriting() throws {
		// Two different inputs sharing a basename, routed into one directory,
		// resolve to the same .ocr.pdf. That must error (exit 64) before any
		// rendering — never silently overwrite one with the other.
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let aDir = directory + "/a"
		let bDir = directory + "/b"
		let outDir = directory + "/out"
		for sub in [aDir, bDir, outDir] {
			try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
		}
		try FileManager.default.copyItem(atPath: TestSupport.fixturePath("hello.png"), toPath: aDir + "/scan.png")
		try FileManager.default.copyItem(atPath: TestSupport.fixturePath("document-photo.png"), toPath: bDir + "/scan.png")

		let result = try TestSupport.run(["searchable-pdf", aDir + "/scan.png", bDir + "/scan.png", "-o", outDir + "/"])

		#expect(result.exitCode == 64, "expected collision usage error; exit \(result.exitCode), stderr: \(result.stderr)")
		#expect(!FileManager.default.fileExists(atPath: outDir + "/scan.ocr.pdf"), "must not write before failing")
	}

	@Test func stdinWithoutExplicitOutputErrors() throws {
		let data = try Data(contentsOf: URL(fileURLWithPath: TestSupport.fixturePath("multipage.pdf")))
		// stdin has no filename to derive [name].ocr.pdf from — must require -o.
		let result = try TestSupport.run(["searchable-pdf", "-"], stdinData: data)
		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
	}

	// MARK: - Helpers

	private func makeTempDir() -> String {
		let path = NSTemporaryDirectory() + "mac-ocr-spdf-out-\(UUID().uuidString)"
		try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
		return path
	}

	private func stage(_ fixture: String, in directory: String) throws -> String {
		let destination = directory + "/" + fixture
		try FileManager.default.copyItem(atPath: TestSupport.fixturePath(fixture), toPath: destination)
		return destination
	}

	private func listing(_ directory: String) -> String {
		((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).joined(separator: ", ")
	}

	private func jsonlObjects(at path: String) throws -> [[String: Any]] {
		let text = try String(contentsOfFile: path, encoding: .utf8)
		return try text.split(separator: "\n").map { line in
			try #require(
				JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
				"invalid JSONL record in \(path): \(line)"
			)
		}
	}

	private func makeBornDigitalPDF() -> Data {
		let stream = "BT /F1 42 Tf 30 70 Td (Hello World) Tj ET"
		let streamBytes = Array(stream.utf8)
		var content = Data("%PDF-1.4\n".utf8)
		var offsets: [Int] = []

		func appendObject(_ body: String) {
			offsets.append(content.count)
			content.append(contentsOf: body.utf8)
		}

		appendObject("1 0 obj\n<</Type /Catalog /Pages 2 0 R>>\nendobj\n")
		appendObject("2 0 obj\n<</Type /Pages /Kids [3 0 R] /Count 1>>\nendobj\n")
		appendObject(
			"3 0 obj\n<</Type /Page /Parent 2 0 R /MediaBox [10 20 310 140] /CropBox [10 20 310 140] /Rotate 90 /Resources <</Font <</F1 5 0 R>>>> /Contents 4 0 R>>\nendobj\n"
		)

		offsets.append(content.count)
		content.append(contentsOf: "4 0 obj\n<</Length \(streamBytes.count)>>\nstream\n".utf8)
		content.append(contentsOf: streamBytes)
		content.append(contentsOf: "\nendstream\nendobj\n".utf8)

		appendObject("5 0 obj\n<</Type /Font /Subtype /Type1 /BaseFont /Helvetica>>\nendobj\n")

		let xrefOffset = content.count
		content.append(contentsOf: "xref\n0 6\n0000000000 65535 f\r\n".utf8)
		for offset in offsets {
			content.append(contentsOf: String(format: "%010d 00000 n\r\n", offset).utf8)
		}
		content.append(contentsOf: "trailer\n<</Size 6 /Root 1 0 R>>\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8)
		return content
	}
}
