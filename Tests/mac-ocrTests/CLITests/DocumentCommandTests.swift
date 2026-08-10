import Foundation
import Testing
import UniformTypeIdentifiers

@Suite(.serialized) struct DocumentCommandTests {

	@Test(.disabled(if: !documentRecognitionAvailable, "Document recognition requires macOS 26."))
	func emitsStructuredJson() throws {
		let result = try TestSupport.run(["document", TestSupport.fixturePath("hello.png"), "--format", "json"])
		#expect(result.exitCode == 0, "stderr: \(result.stderr)")

		let documents = try #require(TestSupport.parseJSON(result.stdout) as? [[String: Any]])
		let document = try #require(documents.first)
		#expect(document["schema"] as? String == "mac-ocr.document")
		#expect(document["schemaVersion"] as? Int == 1)
		#expect(document["text"] as? String == "Hello World")
		let recognizedDocuments = try #require(document["documents"] as? [[String: Any]])
		let content = try #require(recognizedDocuments.first?["content"] as? [String: Any])
		let text = try #require(content["text"] as? [String: Any])
		#expect(text["transcript"] as? String == "Hello World")
		let lines = try #require(text["lines"] as? [[String: Any]])
		#expect(lines.first?["candidates"] == nil)
	}

	@Test(.disabled(if: !documentRecognitionAvailable, "Document recognition requires macOS 26."))
	func emitsConvertedTableRows() throws {
		let directory = try InputMatrixSupport.makeTempDir("document-table")
		defer { try? FileManager.default.removeItem(atPath: directory) }
		let path = directory + "/table.png"
		try InputMatrixSupport.write(DocumentTestSupport.makeTableRaster(), to: path, type: .png)

		let result = try TestSupport.run(["document", path, "--format", "json"])
		#expect(result.exitCode == 0, "stderr: \(result.stderr)")

		let pages = try #require(TestSupport.parseJSON(result.stdout) as? [[String: Any]])
		let documents = try #require(pages.first?["documents"] as? [[String: Any]])
		let content = try #require(documents.first?["content"] as? [String: Any])
		let tables = try #require(content["tables"] as? [[String: Any]])
		let rows = try #require(tables.first?["rows"] as? [[[String: Any]]])
		#expect(rows.count == 2)
		#expect(rows.allSatisfy { $0.count == 2 })
		#expect(rows[0][0]["content"] as? [String: Any] != nil)
	}

	@Test func rejectsFastRecognition() throws {
		let result = try TestSupport.run(["document", TestSupport.fixturePath("hello.png"), "--fast"])
		#expect(result.exitCode == 64)
		#expect(result.stderr.contains("Unknown option '--fast'"), "stderr: \(result.stderr)")
	}

	@Test(.disabled(if: !documentRecognitionAvailable, "Document recognition requires macOS 26."))
	func rejectsRegionalLanguageIdentifier() throws {
		let result = try TestSupport.run(["document", TestSupport.fixturePath("hello.png"), "--language", "en-US"])
		#expect(result.exitCode == 64)
		#expect(result.stderr.contains("Unsupported document recognition language: en-US"), "stderr: \(result.stderr)")
		#expect(result.stderr.contains("Usage: mac-ocr document"), "stderr: \(result.stderr)")
	}

	@Test(.disabled(if: !documentRecognitionAvailable, "Document recognition requires macOS 26."))
	func validatesPipedDocumentLanguage() throws {
		let result = try TestSupport.run(
			["document", "--language", "en-US"],
			stdinData: Data(contentsOf: URL(fileURLWithPath: TestSupport.fixturePath("hello.png")))
		)
		#expect(result.exitCode == 64)
		#expect(result.stderr.contains("Unsupported document recognition language: en-US"), "stderr: \(result.stderr)")
		#expect(result.stderr.contains("Usage: mac-ocr document"), "stderr: \(result.stderr)")
	}
}

private let documentRecognitionAvailable: Bool = {
	if #available(macOS 26.0, *) {
		return true
	}
	return false
}()
