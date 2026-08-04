import Foundation
import MacOcrCore
import PDFKit
import Testing

/// End-to-end CLI tests: spawn the built `mac-ocr` binary and assert on its
/// behavior. Covers the OCR default action, multi-input + PDF streaming,
/// stdin, and the `searchable-pdf` subcommand.
@Suite(.serialized) struct IntegrationTests {
	private func run(_ arguments: [String], stdin: Data? = nil) throws -> TestSupport.RunResult {
		try TestSupport.run(arguments, stdinData: stdin)
	}

	private func fixture(_ name: String) -> String {
		TestSupport.fixturePath(name)
	}

	// MARK: - OCR (default action — no subcommand)

	@Test func defaultActionRecognizesImageText() throws {
		let result = try run([fixture("hello.png")])
		#expect(result.exitCode == 0)
		#expect(result.stdout.contains("Hello World"))
	}

	@Test func explicitOcrAliasStillWorks() throws {
		let result = try run(["ocr", fixture("hello.png")])
		#expect(result.exitCode == 0)
		#expect(result.stdout.contains("Hello World"))
	}

	@Test func jsonOutputCarriesText() throws {
		let result = try run([fixture("hello.png"), "--format", "json"])
		#expect(result.exitCode == 0)
		let json = (try TestSupport.parseJSON(result.stdout)) as! [[String: Any]]
		#expect((json[0]["text"] as? String)?.contains("Hello World") == true)
	}

	@Test func multipleImagesStreamOneJsonlLineEach() throws {
		let result = try run([fixture("hello.png"), fixture("document-photo.png"), "--format", "jsonl"])
		#expect(result.exitCode == 0)
		let lines = result.stdout.split(separator: "\n").filter { !$0.isEmpty }
		#expect(lines.count == 2)
	}

	@Test func pdfStreamsOneLinePerPage() throws {
		let result = try run([fixture("multipage.pdf"), "--format", "jsonl"])
		#expect(result.exitCode == 0)
		let lines = result.stdout.split(separator: "\n").filter { !$0.isEmpty }
		#expect(lines.count == 3)
		#expect(result.stdout.contains("Page One"))
		#expect(result.stdout.contains("Page Three"))
	}

	@Test func stdinIsRecognizedByDefault() throws {
		let data = try Data(contentsOf: URL(fileURLWithPath: fixture("hello.png")))
		let result = try run([], stdin: data)
		#expect(result.exitCode == 0)
		#expect(result.stdout.contains("Hello World"))
	}

	@Test func missingFileExitsNonZero() throws {
		let result = try run([fixture("does-not-exist.png")])
		#expect(result.exitCode != 0)
	}

	@Test func jsonOutputIsAlwaysValidJsonEvenWhenAllInputsFail() throws {
		// stdout must stay parseable for JSON consumers — emit `[]`, not empty
		// output, when nothing was recognized. Errors go to stderr / exit code.
		let result = try run([fixture("does-not-exist.png"), "--format", "json"])
		#expect(result.exitCode != 0)
		let json = try TestSupport.parseJSON(result.stdout) as? [Any]
		#expect(json != nil, "stdout was not valid JSON: \(result.stdout)")
		#expect(json?.isEmpty == true)
	}

	@Test func versionFlagPrintsVersion() throws {
		let result = try run(["--version"])
		#expect(result.exitCode == 0)
		// Assert against the injected constant, not a literal — version
		// stamping (scripts/write-version.mjs) must never break this test.
		#expect(result.stdout.contains(macOcrVersion))
	}

	@Test func outputTemplateWritesAlongsideInput() throws {
		// A `[dir]/[name]` template writes output next to each input — the
		// replacement for the removed `--sidecar` flag.
		let dir = NSTemporaryDirectory() + "mac-ocr-alongside-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let input = dir + "/img.png"
		try FileManager.default.copyItem(atPath: fixture("hello.png"), toPath: input)

		let result = try run([input, "-o", "[dir]/[name].txt"])
		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		let text = (try? String(contentsOfFile: dir + "/img.txt", encoding: .utf8)) ?? ""
		#expect(text.contains("Hello World"), "expected img.txt alongside the input")
	}

	@Test func outputFlagWritesToGivenPath() throws {
		// `--output <path>` is a valued option on ocr (consistent with
		// searchable-pdf): the destination is written, not treated as an input.
		let dir = NSTemporaryDirectory() + "mac-ocr-output-\(UUID().uuidString)"
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(atPath: dir) }
		let outPath = dir + "/result.txt"

		let result = try run([fixture("hello.png"), "--output", outPath])
		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		#expect(((try? String(contentsOfFile: outPath, encoding: .utf8)) ?? "").contains("Hello World"))
	}

	// MARK: - searchable-pdf

	@Test func searchablePdfWritesSelectablePdfFile() throws {
		let output = FileManager.default.temporaryDirectory
			.appendingPathComponent("mac-ocr-it-\(UUID().uuidString).pdf")
		defer { try? FileManager.default.removeItem(at: output) }

		let result = try run(["searchable-pdf", fixture("multipage.pdf"), "-o", output.path])
		#expect(result.exitCode == 0)

		let document = try #require(PDFDocument(url: output))
		#expect(document.pageCount == 3)
		#expect((document.string ?? "").contains("Page Two"))
	}

	// MARK: - languages

	@Test func languagesSubcommandListsLanguages() throws {
		let result = try run(["languages"])
		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		let languages = result.stdout.split(separator: "\n").filter { !$0.isEmpty }
		#expect(languages.count > 0)
		#expect(result.stdout.contains("en-US"))
	}

	@Test func languagesSubcommandAcceptsFast() throws {
		let result = try run(["languages", "--fast"])
		#expect(result.exitCode == 0, "stderr: \(result.stderr)")
		#expect(!result.stdout.split(separator: "\n").filter { !$0.isEmpty }.isEmpty)
	}
}
