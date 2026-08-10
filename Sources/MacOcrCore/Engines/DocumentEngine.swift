import CoreGraphics
import Darwin
import Foundation
import Vision

public struct DocumentUnavailableError: LocalizedError {
	public init() {}

	public var errorDescription: String? {
		"Document recognition requires macOS 26 or later"
	}
}

public enum DocumentEngine {
	public static func checkAvailability() throws {
		guard #available(macOS 26.0, *) else {
			throw DocumentUnavailableError()
		}
	}

	public static func prepare(options: DocumentOptions) throws -> DocumentOptions {
		guard #available(macOS 26.0, *) else {
			throw DocumentUnavailableError()
		}
		return try prepareDocumentOptions(options)
	}

	public static func run(session: VisionSession, options: DocumentOptions) async throws -> DocumentResult {
		guard #available(macOS 26.0, *) else {
			throw DocumentUnavailableError()
		}
		try Task.checkCancellation()
		return try await recognizeDocument(session: session, options: options)
	}
}

@available(macOS 26.0, *)
private func prepareDocumentOptions(_ options: DocumentOptions) throws -> DocumentOptions {
	guard !options.languages.isEmpty else {
		return options
	}

	let request = RecognizeDocumentsRequest()
	let supported = Dictionary(
		request.supportedRecognitionLanguages.map { language in
			(language.minimalIdentifier.lowercased(), language.minimalIdentifier)
		},
		uniquingKeysWith: { first, _ in first }
	)
	var unsupported: [String] = []
	var languages: [String] = []
	for language in options.languages {
		guard let canonical = supported[language.lowercased()] else {
			unsupported.append(language)
			continue
		}
		languages.append(canonical)
	}
	guard unsupported.isEmpty else {
		let label = unsupported.count == 1 ? "language" : "languages"
		throw DocumentLanguageError("Unsupported document recognition \(label): \(unsupported.joined(separator: ", "))")
	}

	var canonicalizedOptions = options
	canonicalizedOptions.languages = languages
	return canonicalizedOptions
}

public struct DocumentLanguageError: LocalizedError {
	public let message: String

	public init(_ message: String) {
		self.message = message
	}

	public var errorDescription: String? { message }
}

@available(macOS 26.0, *)
private func recognizeDocument(session: VisionSession, options: DocumentOptions) async throws -> DocumentResult {
	var request = RecognizeDocumentsRequest()
	var textOptions = request.textRecognitionOptions
	textOptions.minimumTextHeightFraction = options.minimumTextHeight ?? textOptions.minimumTextHeightFraction
	textOptions.automaticallyDetectLanguage = options.languages.isEmpty
	textOptions.recognitionLanguages = options.languages.map(Locale.Language.init(identifier:))
	textOptions.useLanguageCorrection = options.usesLanguageCorrection
	textOptions.customWords = options.customWords
	textOptions.maximumCandidateCount = options.maxCandidates
	request.textRecognitionOptions = textOptions
	request.barcodeDetectionOptions.enabled = false
	if let regionOfInterest = options.regionOfInterest {
		request.regionOfInterest = NormalizedRect(normalizedRect: CGRect(regionOfInterest))
	}

	let observations: [DocumentObservation]
	do {
		observations = try await performDocumentRequest(
			request,
			session: session
		)
	} catch {
		try Task.checkCancellation()
		throw error
	}
	try Task.checkCancellation()

	let documents = observations.map { observation in
		RecognizedDocument(confidence: observation.confidence, content: documentContainer(observation.document, maxCandidates: options.maxCandidates))
	}
	return DocumentResult(
		requestRevision: 1,
		text: documents.map(\.content.text.transcript).joined(separator: "\n"),
		documents: documents
	)
}

@available(macOS 26.0, *)
private func performDocumentRequest(
	_ request: RecognizeDocumentsRequest,
	session: VisionSession
) async throws -> [DocumentObservation] {
	let savedStandardOutput = dup(STDOUT_FILENO)
	guard savedStandardOutput >= 0 else {
		return try await request.perform(on: session.image, orientation: session.orientation)
	}
	let nullOutput = open("/dev/null", O_WRONLY)
	guard nullOutput >= 0 else {
		close(savedStandardOutput)
		return try await request.perform(on: session.image, orientation: session.orientation)
	}
	guard dup2(nullOutput, STDOUT_FILENO) >= 0 else {
		close(nullOutput)
		close(savedStandardOutput)
		return try await request.perform(on: session.image, orientation: session.orientation)
	}
	close(nullOutput)
	defer {
		fflush(stdout)
		dup2(savedStandardOutput, STDOUT_FILENO)
		close(savedStandardOutput)
	}
	return try await request.perform(on: session.image, orientation: session.orientation)
}

@available(macOS 26.0, *)
private func documentContainer(_ container: DocumentObservation.Container, maxCandidates: Int) -> DocumentContainer {
	DocumentContainer(
		boundingRegion: documentRegion(container.boundingRegion),
		text: documentText(container.text, maxCandidates: maxCandidates),
		title: container.title.map { documentText($0, maxCandidates: maxCandidates) },
		paragraphs: container.paragraphs.map { documentText($0, maxCandidates: maxCandidates) },
		tables: container.tables.map { documentTable($0, maxCandidates: maxCandidates) },
		lists: container.lists.map { documentList($0, maxCandidates: maxCandidates) }
	)
}

@available(macOS 26.0, *)
private func documentText(_ text: DocumentObservation.Container.Text, maxCandidates: Int) -> DocumentText {
	DocumentText(
		transcript: text.transcript,
		boundingRegion: documentRegion(text.boundingRegion),
		alignment: text.textAlignment.map(documentTextAlignment),
		lines: text.lines.map { documentTextLine($0, maxCandidates: maxCandidates) }
	)
}

@available(macOS 26.0, *)
private func documentTextLine(_ line: RecognizedTextObservation, maxCandidates: Int) -> DocumentTextLine {
	let candidates = line.topCandidates(maxCandidates).dropFirst().map { candidate in
		TextCandidate(text: candidate.string, confidence: candidate.confidence)
	}
	return DocumentTextLine(
		transcript: line.transcript,
		confidence: line.confidence,
		boundingRegion: documentRegion(line.boundingRegion),
		candidates: candidates,
		recognitionLanguages: line.recognitionLanguages.map(\.minimalIdentifier),
		isTitle: line.isTitle,
		textDirection: line.textDirection.map(documentTextDirection),
		shouldWrapToNextLine: line.shouldWrapToNextLine
	)
}

@available(macOS 26.0, *)
private func documentTable(_ table: DocumentObservation.Container.Table, maxCandidates: Int) -> DocumentTable {
	DocumentTable(
		boundingRegion: documentRegion(table.boundingRegion),
		rows: table.rows.map { row in
			row.map { cell in
				DocumentTableCell(
					rowRange: DocumentIndexRange(start: cell.rowRange.lowerBound, end: cell.rowRange.upperBound),
					columnRange: DocumentIndexRange(start: cell.columnRange.lowerBound, end: cell.columnRange.upperBound),
					content: documentContainer(cell.content, maxCandidates: maxCandidates)
				)
			}
		}
	)
}

@available(macOS 26.0, *)
private func documentList(_ list: DocumentObservation.Container.List, maxCandidates: Int) -> DocumentList {
	DocumentList(
		boundingRegion: documentRegion(list.boundingRegion),
		items: list.items.map { item in
			DocumentListItem(
				markerType: item.markerType.map(documentListMarker),
				markerText: item.markerString,
				text: item.itemString,
				content: documentContainer(item.content, maxCandidates: maxCandidates)
			)
		}
	)
}

@available(macOS 26.0, *)
private func documentRegion(_ region: NormalizedRegion) -> DocumentRegion {
	DocumentRegion(
		points: region.points.map { point in
			DocumentPoint(x: Double(point.x), y: Double(1 - point.y))
		},
		boundingBox: BoundingBox(region.boundingBox.cgRect)
	)
}

@available(macOS 26.0, *)
private func documentTextAlignment(_ alignment: DocumentObservation.Container.Text.Alignment) -> DocumentTextAlignment {
	switch alignment {
	case .center:
		.center
	case .leading:
		.leading
	case .trailing:
		.trailing
	@unknown default:
		.leading
	}
}

@available(macOS 26.0, *)
private func documentTextDirection(_ direction: RecognizedTextObservation.Direction) -> DocumentTextDirection {
	switch direction {
	case .leftToRight:
		.leftToRight
	case .rightToLeft:
		.rightToLeft
	case .topToBottom:
		.topToBottom
	@unknown default:
		.unknown
	}
}

@available(macOS 26.0, *)
private func documentListMarker(_ marker: DocumentObservation.Container.List.Marker) -> DocumentListMarker {
	switch marker {
	case .bullet:
		.bullet
	case .hyphen:
		.hyphen
	case .lowercaseLatin:
		.lowercaseLatin
	case .uppercaseLatin:
		.uppercaseLatin
	case .decimal:
		.decimal
	case .decorativeDecimal:
		.decorativeDecimal
	case .compositeDecimal:
		.compositeDecimal
	@unknown default:
		.unknown
	}
}
