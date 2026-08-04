import Foundation
import Testing

@testable import MacOcrCore

@Suite("OutputTemplate")
struct OutputTemplateTests {

	// MARK: - Placeholder rendering

	@Test func nameplaceholderRendersFilenameWithoutExtension() throws {
		let template = try OutputTemplate(template: "[name].txt")
		let result = try template.render(context: makeContext(sourcePath: "/receipts/IMG_1234.jpg"))
		#expect(result == "IMG_1234.txt")
	}

	@Test func extPlaceholderRendersExtensionWithoutDot() throws {
		let template = try OutputTemplate(template: "out.[ext]")
		let result = try template.render(context: makeContext(sourcePath: "/photos/photo.JPEG"))
		#expect(result == "out.JPEG")
	}

	@Test func suffixPlaceholderWasRemovedAndIsRejected() {
		// `[suffix]` was a reserved always-empty relic of the removed artifact
		// engines; it must now fail like any unknown placeholder.
		#expect(throws: (any Error).self) {
			try OutputTemplate(template: "[name].[suffix].txt")
		}
	}

	@Test func pagePlaceholderRendersOneBasedIndex() throws {
		let template = try OutputTemplate(template: "[name]-p[page].[ext]")
		let result = try template.render(context: makeContext(sourcePath: "/a/doc.pdf", page: 3))
		#expect(result == "doc-p3.pdf")
	}

	@Test func pagecountPlaceholderRendersTotalPages() throws {
		let template = try OutputTemplate(template: "[page]of[pagecount]")
		let result = try template.render(context: makeContext(sourcePath: "/a/b.png", page: 2, pageCount: 5))
		#expect(result == "2of5")
	}

	@Test func dirPlaceholderRendersInputDirectory() throws {
		let template = try OutputTemplate(template: "[dir]/out/[name].txt")
		let result = try template.render(context: makeContext(sourcePath: "/receipts/IMG_1234.jpg"))
		#expect(result == "/receipts/out/IMG_1234.txt")
	}

	@Test func dirPlaceholderIsEmptyForUrlDerivedFilenames() throws {
		let template = try OutputTemplate(template: "[dir][name].txt")
		let result = try template.render(context: makeContext(sourcePath: "photo.jpg"))
		#expect(result == "photo.txt")
	}

	@Test func dirPlaceholderWithSlashIsRelativeForCurrentDirectoryInput() throws {
		let template = try OutputTemplate(template: "[dir]/[name].txt")
		let result = try template.render(context: makeContext(sourcePath: "photo.jpg"))
		#expect(result == "photo.txt")
		#expect(!result.hasPrefix("/"))
	}

	@Test func dirPlaceholderWithSlashIsRelativeForUrlDerivedFilename() throws {
		let template = try OutputTemplate(template: "[dir]/out/[name].txt")
		let result = try template.render(context: makeContext(sourcePath: "remote-photo.jpg"))
		#expect(result == "out/remote-photo.txt")
		#expect(!result.hasPrefix("/"))
	}

	@Test func dirPlaceholderWithSlashIsRelativeForStdinTemplate() throws {
		let template = try OutputTemplate(template: "[dir]/page-[page].txt")
		let result = try template.render(context: makeContext(sourcePath: nil))
		#expect(result == "page-1.txt")
		#expect(!result.hasPrefix("/"))
	}

	@Test func dirPlaceholderPreservesRelativeInputDirectory() throws {
		let template = try OutputTemplate(template: "[dir]/out/[name].txt")
		let result = try template.render(context: makeContext(sourcePath: "receipts/IMG_1234.jpg"))
		#expect(result == "receipts/out/IMG_1234.txt")
	}

	@Test func allPlaceholdersTogether() throws {
		let template = try OutputTemplate(template: "[dir]/[name]-p[page]of[pagecount].[ext]")
		let result = try template.render(
			context: makeContext(
				sourcePath: "/scans/receipt.jpg",
				page: 2,
				pageCount: 10
			))
		#expect(result == "/scans/receipt-p2of10.jpg")
	}

	// MARK: - Literal passthrough

	@Test func literalTextPassesThrough() throws {
		let template = try OutputTemplate(template: "fixed/path/output.txt")
		let result = try template.render(context: makeContext(sourcePath: "/a/b.png"))
		#expect(result == "fixed/path/output.txt")
	}

	@Test func unclosedBracketPassesThrough() throws {
		// Unclosed `[` is treated as literal — no error
		let template = try OutputTemplate(template: "path/[name")
		let result = try template.render(context: makeContext(sourcePath: "/a/b.png"))
		#expect(result == "path/[name")
	}

	// MARK: - Unknown placeholder errors

	@Test func unknownPlaceholderThrowsAtParseTime() {
		#expect(throws: (any Error).self) {
			try OutputTemplate(template: "[foo]")
		}
	}

	@Test func unknownPlaceholderErrorMessageNamesValidSet() throws {
		do {
			_ = try OutputTemplate(template: "[unknown]")
			Issue.record("Expected error to be thrown")
		} catch let error as MessageError {
			#expect(error.message.contains("[name]"))
			#expect(error.message.contains("[ext]"))
			#expect(error.message.contains("[page]"))
			#expect(error.message.contains("[pagecount]"))
			#expect(error.message.contains("[dir]"))
		}
	}

	// MARK: - Stdin / no-path errors

	@Test func nameplaceholderErrorsOnStdinInput() {
		let template = try? OutputTemplate(template: "[name].txt")
		guard let template else {
			Issue.record("Template parse should succeed")
			return
		}
		let context = makeContext(sourcePath: nil)
		#expect(throws: (any Error).self) {
			try template.render(context: context)
		}
	}

	@Test func extPlaceholderErrorsOnStdinInput() {
		let template = try? OutputTemplate(template: "out.[ext]")
		guard let template else {
			Issue.record("Template parse should succeed")
			return
		}
		let context = makeContext(sourcePath: nil)
		#expect(throws: (any Error).self) {
			try template.render(context: context)
		}
	}

	// MARK: - referencesPageNumber (drives per-page vs consolidated file output)

	@Test func referencesPageNumberTrueWhenPagePresent() throws {
		let template = try OutputTemplate(template: "[name]-[page].txt")
		#expect(template.referencesPageNumber)
	}

	@Test func referencesPageNumberFalseForPagecountAlone() throws {
		// [pagecount] alone is informational and must NOT trigger the
		// one-file-per-page split — only [page] does.
		let template = try OutputTemplate(template: "[name]-[pagecount].txt")
		#expect(!template.referencesPageNumber)
	}

	@Test func referencesSourceFilenameTrueWhenNameOrExtPresent() throws {
		#expect(try OutputTemplate(template: "[name].txt").referencesSourceFilename)
		#expect(try OutputTemplate(template: "[ext]").referencesSourceFilename)
	}

	@Test func referencesSourceFilenameFalseForDirOnlyTemplate() throws {
		#expect(!(try OutputTemplate(template: "[dir]/page-[page].txt").referencesSourceFilename))
	}

	// MARK: - Bug 1: [ext] empty for extension-less files

	/// `[ext]` renders as `""` for extension-less inputs. With the template
	/// `[name].[ext].txt`, this produces `noext..txt` (double-dot). This is
	/// documented behaviour — users should use `[name][ext]` when `[ext]`
	/// may be empty. This test records the actual output so a regression
	/// would be caught.
	@Test func extPlaceholderEmptyForExtensionlessFile() throws {
		let template = try OutputTemplate(template: "[name].[ext].txt")
		let result = try template.render(context: makeContext(sourcePath: "/tmp/noext"))
		// [ext] is "" so the literal dot between [name] and [ext] is present,
		// resulting in a double-dot before the static ".txt" suffix.
		#expect(result == "noext..txt")
	}

	@Test func extPlaceholderEmptyNoDoubleDotWhenNoSeparator() throws {
		// Recommended pattern: [name][ext] (no dot separator) avoids double-dot.
		let template = try OutputTemplate(template: "[name][ext].txt")
		let result = try template.render(context: makeContext(sourcePath: "/tmp/noext"))
		#expect(result == "noext.txt")
	}

	@Test func nameStripOnlyLastDotComponent() throws {
		// [name] removes only the last extension component.
		let template = try OutputTemplate(template: "[name].out")
		let result = try template.render(context: makeContext(sourcePath: "/tmp/my.backup.2024.jpg"))
		#expect(result == "my.backup.2024.out")
	}
}

@Suite("URL output filenames")
struct URLOutputFilenameTests {

	@Test func extractsFilenameFromURLPath() {
		#expect(urlOutputFilename(from: "https://example.com/scans/receipt.png") == "receipt.png")
	}

	@Test func ignoresQueryAndFragment() {
		#expect(urlOutputFilename(from: "https://example.com/scans/receipt%201.png?token=abc#page") == "receipt 1.png")
	}

	@Test func rejectsURLWithoutFilename() {
		#expect(urlOutputFilename(from: "https://example.com/scans/") == nil)
		#expect(urlOutputFilename(from: "https://example.com/") == nil)
	}

	@Test func rejectsDecodedTraversalOrSeparators() {
		#expect(urlOutputFilename(from: "https://example.com/scans/%2E%2E") == nil)
		#expect(urlOutputFilename(from: "https://example.com/scans/a%2Fb.png") == nil)
	}
}

// MARK: - isTemplateString

@Suite("isTemplateString")
struct IsTemplateStringTests {

	@Test func detectsKnownPlaceholder() {
		#expect(isTemplateString("[name].txt"))
		#expect(isTemplateString("[ext]"))
		#expect(isTemplateString("[page]"))
		#expect(isTemplateString("[pagecount]"))
		#expect(isTemplateString("[dir]"))
	}

	@Test func caseInsensitiveDetection() {
		#expect(isTemplateString("[NAME].txt"))
		#expect(isTemplateString("[EXT]"))
	}

	@Test func returnsFalseForPlainPath() {
		#expect(!isTemplateString("output/file.png"))
		#expect(!isTemplateString("cropped/"))
		#expect(!isTemplateString("output.txt"))
	}

	@Test func returnsTrueForUnknownBrackets() {
		// Any [identifier] syntax triggers template detection — the parser then
		// rejects unknown names with a clear error (not a silent passthrough).
		#expect(isTemplateString("[foo]"))
		#expect(isTemplateString("[bar].txt"))
	}
}

// MARK: - hasMalformedPlaceholder

@Suite("hasMalformedPlaceholder")
struct HasMalformedPlaceholderTests {

	@Test func returnsFalseForNoBrackets() {
		#expect(!hasMalformedPlaceholder("output.txt"))
		#expect(!hasMalformedPlaceholder("dir/file.png"))
	}

	@Test func returnsFalseWhenValidPlaceholderPresent() {
		#expect(!hasMalformedPlaceholder("[name].txt"))
		#expect(!hasMalformedPlaceholder("out/[name]-[page].txt"))
	}

	@Test func returnsTrueForDoubledBrackets() {
		#expect(hasMalformedPlaceholder("[[name]].txt"))
	}

	@Test func returnsTrueForBracketWithSpaceInside() {
		#expect(hasMalformedPlaceholder("[na me].txt"))
	}

	@Test func returnsTrueForUnclosedBracketWithContents() {
		// Unclosed `[` alone doesn't qualify as malformed — the OutputTemplate
		// parser silently passes it through as a literal. `hasMalformedPlaceholder`
		// only fires when there is a `[` that is NOT part of a valid identifier.
		// An unclosed `[foo` (no `]`) has no `]` so isTemplateString returns false
		// but `[` is still present, so hasMalformedPlaceholder returns true.
		#expect(hasMalformedPlaceholder("[noclose.txt"))
	}
}

// MARK: - parseOutputValue

@Suite("parseOutputValue")
struct ParseOutputValueTests {

	@Test func templateModeForKnownPlaceholder() throws {
		let mode = try parseOutputValue("[name].txt")
		guard case .template = mode else {
			Issue.record("Expected .template, got \(mode)")
			return
		}
	}

	@Test func directoryModeForTrailingSlash() throws {
		let mode = try parseOutputValue("output/")
		guard case .directory(let dir) = mode else {
			Issue.record("Expected .directory, got \(mode)")
			return
		}
		#expect(dir == "output/")
	}

	@Test func directoryModeForExistingDirectoryWithoutTrailingSlash() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("mac-ocr-existing-output-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let mode = try parseOutputValue(directory.path)
		guard case .directory(let dir) = mode else {
			Issue.record("Expected .directory, got \(mode)")
			return
		}
		#expect(dir == directory.path)
	}

	@Test func staticModeForBareName() throws {
		let mode = try parseOutputValue("result")
		guard case .static(let path) = mode else {
			Issue.record("Expected .static, got \(mode)")
			return
		}
		#expect(path == "result")
	}

	@Test func staticModeForPathWithExtension() throws {
		let mode = try parseOutputValue("result.png")
		guard case .static(let path) = mode else {
			Issue.record("Expected .static, got \(mode)")
			return
		}
		#expect(path == "result.png")
	}

	@Test func staticModeForPathWithSeparator() throws {
		let mode = try parseOutputValue("dir/output.png")
		guard case .static(let path) = mode else {
			Issue.record("Expected .static, got \(mode)")
			return
		}
		#expect(path == "dir/output.png")
	}

	@Test func unknownPlaceholderInTemplateThrows() {
		#expect(throws: (any Error).self) {
			try parseOutputValue("[unknown].txt")
		}
	}

	// MARK: - Bug 2: malformed placeholder syntax

	/// `[[name]].txt` — the inner token `[name` contains `[` which fails the
	/// identifier check in `isTemplateString`, so it would previously fall
	/// through to static mode and silently produce a file named `[[name]].txt`.
	/// After the fix it errors with a clear message.
	@Test func doubledBracketMalformedPlaceholderThrows() {
		#expect(throws: (any Error).self) {
			try parseOutputValue("[[name]].txt")
		}
	}

	@Test func malformedPlaceholderErrorMessageIsHelpful() throws {
		do {
			_ = try parseOutputValue("[[name]].txt")
			Issue.record("Expected error")
		} catch let error as MessageError {
			#expect(error.message.contains("Malformed"))
			#expect(error.message.contains("[name]"))
		}
	}

	@Test func bracketInPathWithNoPlaceholderThrows() {
		// A path like `output[0].txt` contains `[` but no valid placeholder —
		// should error rather than silently route to static mode.
		#expect(throws: (any Error).self) {
			try parseOutputValue("output[0].txt")
		}
	}
}

// MARK: - Helper

private func makeContext(
	sourcePath: String?,
	page: Int = 1,
	pageCount: Int = 1
) -> OutputTemplate.Context {
	OutputTemplate.Context(
		sourcePath: sourcePath,
		page: page,
		pageCount: pageCount
	)
}
