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

	@Test func stdoutWithMultipleInputsErrors() throws {
		let directory = makeTempDir()
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let a = try stage("hello.png", in: directory)
		let b = try stage("document-photo.png", in: directory)

		let result = try TestSupport.run(["searchable-pdf", a, b, "-o", "-"])
		#expect(result.exitCode == 64, "expected usage error; exit \(result.exitCode), stderr: \(result.stderr)")
	}

	@Test func stdoutSingleInputEmitsPdfBytes() throws {
		let result = try TestSupport.run(["searchable-pdf", TestSupport.fixturePath("hello.png"), "-o", "-"])
		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		#expect(result.stdoutData.prefix(5) == Data("%PDF-".utf8))
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
}
