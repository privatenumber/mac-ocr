import Foundation
import Testing

@testable import MacOcrCore

@Suite(.serialized) final class DocumentEngineTests {
	init() { VisionGate.shared.acquireBlocking() }
	deinit { VisionGate.shared.release() }

	@Test(.disabled(if: !documentRecognitionAvailable, "Document recognition requires macOS 26."))
	func recognizesStructuredHelloWorld() async throws {
		let loaded = try EngineTestSupport.loadImage("hello.png")
		let result = try await DocumentEngine.run(
			session: VisionSession(image: loaded.image, orientation: loaded.orientation),
			options: DocumentOptions()
		)

		#expect(result.schema == "mac-ocr.document")
		#expect(result.schemaVersion == 1)
		#expect(result.requestRevision == 1)
		#expect(result.text.contains("Hello World"))
		let document = try #require(result.documents.first)
		let line = try #require(document.content.text.lines.first)
		#expect(line.transcript.contains("Hello World"))
		#expect(line.confidence > 0)
		#expect(line.boundingRegion.points.count == 4)
		#expect(line.boundingRegion.boundingBox.y > 0)
		#expect(line.boundingRegion.boundingBox.y < 1)
		#expect(line.candidates.isEmpty)
	}

	@Test(.disabled(if: !documentRecognitionAvailable, "Document recognition requires macOS 26."))
	func acceptsMinimalLanguageIdentifier() throws {
		let options = try DocumentEngine.prepare(options: DocumentOptions(languages: ["en"]))
		#expect(options.languages == ["en"])
	}

	@Test(.disabled(if: !documentRecognitionAvailable, "Document recognition requires macOS 26."))
	func rejectsRegionalLanguageIdentifier() {
		#expect(throws: DocumentLanguageError.self) {
			try DocumentEngine.prepare(options: DocumentOptions(languages: ["en-US"]))
		}
	}

	@Test(.disabled(if: !documentRecognitionAvailable, "Document recognition requires macOS 26."))
	func requestedCandidatesExcludeTheTopTranscript() async throws {
		let loaded = try EngineTestSupport.loadImage("hello.png")
		let result = try await DocumentEngine.run(
			session: VisionSession(image: loaded.image, orientation: loaded.orientation),
			options: DocumentOptions(maxCandidates: 3)
		)

		let line = try #require(result.documents.first?.content.text.lines.first)
		#expect(line.candidates.count <= 2)
		#expect(!line.candidates.contains { $0.text == line.transcript && $0.confidence == line.confidence })
	}

	@Test(.disabled(if: !documentRecognitionAvailable, "Document recognition requires macOS 26."))
	func regionOfInterestUsesTopLeftCoordinates() async throws {
		let loaded = try EngineTestSupport.loadImage("hello.png")
		let full = try await DocumentEngine.run(
			session: VisionSession(image: loaded.image, orientation: loaded.orientation),
			options: DocumentOptions()
		)
		let topEdge = try await DocumentEngine.run(
			session: VisionSession(image: loaded.image, orientation: loaded.orientation),
			options: DocumentOptions(regionOfInterest: BoundingBox(x: 0, y: 0, width: 1, height: 0.05))
		)

		#expect(full.text.contains("Hello World"))
		#expect(topEdge.text.isEmpty)
	}

	@Test(.disabled(if: !documentRecognitionAvailable, "Document recognition requires macOS 26."))
	func recognizesTableCellsInRows() async throws {
		let result = try await DocumentEngine.run(
			session: VisionSession(image: DocumentTestSupport.makeTableRaster()),
			options: DocumentOptions()
		)

		let table = try #require(result.documents.first?.content.tables.first)
		#expect(table.rows.count == 2)
		#expect(table.rows.allSatisfy { $0.count == 2 })
		#expect(table.rows[0][0].content.text.transcript == "ALPHA")
		#expect(table.rows[0][1].content.text.transcript == "BETA")
		#expect(table.rows[1][0].content.text.transcript == "GAMMA")
		#expect(table.rows[1][1].content.text.transcript == "DELTA")
	}

	@Test(.disabled(if: !documentRecognitionAvailable, "Document recognition requires macOS 26."))
	func recognizesNumberedListItems() async throws {
		let result = try await DocumentEngine.run(
			session: VisionSession(image: DocumentTestSupport.makeNumberedListRaster()),
			options: DocumentOptions()
		)

		let list = try #require(result.documents.first?.content.lists.first)
		#expect(list.items.map(\.markerType) == [.decimal, .decimal, .decimal])
		#expect(list.items.map(\.text) == ["ALPHA", "BETA", "GAMMA"])
	}

}

private let documentRecognitionAvailable: Bool = {
	if #available(macOS 26.0, *) {
		return true
	}
	return false
}()
