import Foundation

public struct DocumentOptions: Sendable {
	public var languages: [String] = []
	public var usesLanguageCorrection = true
	public var customWords: [String] = []
	public var minimumTextHeight: Float?
	public var maxCandidates = 1
	public var regionOfInterest: BoundingBox?

	public init(
		languages: [String] = [],
		usesLanguageCorrection: Bool = true,
		customWords: [String] = [],
		minimumTextHeight: Float? = nil,
		maxCandidates: Int = 1,
		regionOfInterest: BoundingBox? = nil
	) {
		self.languages = languages
		self.usesLanguageCorrection = usesLanguageCorrection
		self.customWords = customWords
		self.minimumTextHeight = minimumTextHeight
		self.maxCandidates = maxCandidates
		self.regionOfInterest = regionOfInterest
	}
}

/// Stable structured-document payload. This is intentionally independent from
/// Vision's Codable models so Apple can evolve its representation freely.
public struct DocumentResult: ResultPayload {
	public let schema = "mac-ocr.document"
	public let schemaVersion = 1
	public let requestRevision: Int
	public let text: String
	public let documents: [RecognizedDocument]

	public var textOutput: String { text }

	public init(requestRevision: Int, text: String, documents: [RecognizedDocument]) {
		self.requestRevision = requestRevision
		self.text = text
		self.documents = documents
	}
}

public struct RecognizedDocument: Encodable, Sendable {
	public let confidence: Float
	public let content: DocumentContainer

	public init(confidence: Float, content: DocumentContainer) {
		self.confidence = confidence
		self.content = content
	}
}

public struct DocumentContainer: Encodable, Sendable {
	public let boundingRegion: DocumentRegion
	public let text: DocumentText
	public let title: DocumentText?
	public let paragraphs: [DocumentText]
	public let tables: [DocumentTable]
	public let lists: [DocumentList]

	public init(
		boundingRegion: DocumentRegion,
		text: DocumentText,
		title: DocumentText?,
		paragraphs: [DocumentText],
		tables: [DocumentTable],
		lists: [DocumentList]
	) {
		self.boundingRegion = boundingRegion
		self.text = text
		self.title = title
		self.paragraphs = paragraphs
		self.tables = tables
		self.lists = lists
	}
}

public struct DocumentText: Encodable, Sendable {
	public let transcript: String
	public let boundingRegion: DocumentRegion
	public let alignment: DocumentTextAlignment?
	public let lines: [DocumentTextLine]

	public init(
		transcript: String,
		boundingRegion: DocumentRegion,
		alignment: DocumentTextAlignment?,
		lines: [DocumentTextLine]
	) {
		self.transcript = transcript
		self.boundingRegion = boundingRegion
		self.alignment = alignment
		self.lines = lines
	}
}

public enum DocumentTextAlignment: String, Encodable, Sendable {
	case center, leading, trailing
}

public struct DocumentTextLine: Encodable, Sendable {
	public let transcript: String
	public let confidence: Float
	public let boundingRegion: DocumentRegion
	public let candidates: [TextCandidate]
	public let recognitionLanguages: [String]
	public let isTitle: Bool
	public let textDirection: DocumentTextDirection?
	public let shouldWrapToNextLine: Bool?

	private enum CodingKeys: String, CodingKey {
		case transcript, confidence, boundingRegion, candidates, recognitionLanguages, isTitle, textDirection, shouldWrapToNextLine
	}

	public init(
		transcript: String,
		confidence: Float,
		boundingRegion: DocumentRegion,
		candidates: [TextCandidate],
		recognitionLanguages: [String],
		isTitle: Bool,
		textDirection: DocumentTextDirection?,
		shouldWrapToNextLine: Bool?
	) {
		self.transcript = transcript
		self.confidence = confidence
		self.boundingRegion = boundingRegion
		self.candidates = candidates
		self.recognitionLanguages = recognitionLanguages
		self.isTitle = isTitle
		self.textDirection = textDirection
		self.shouldWrapToNextLine = shouldWrapToNextLine
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(transcript, forKey: .transcript)
		try container.encode(confidence, forKey: .confidence)
		try container.encode(boundingRegion, forKey: .boundingRegion)
		// Match ordinary OCR: omit the redundant candidates field at the default.
		if !candidates.isEmpty {
			try container.encode(candidates, forKey: .candidates)
		}
		try container.encode(recognitionLanguages, forKey: .recognitionLanguages)
		try container.encode(isTitle, forKey: .isTitle)
		try container.encodeIfPresent(textDirection, forKey: .textDirection)
		try container.encodeIfPresent(shouldWrapToNextLine, forKey: .shouldWrapToNextLine)
	}
}

public enum DocumentTextDirection: String, Encodable, Sendable {
	case leftToRight, rightToLeft, topToBottom, unknown
}

public struct DocumentTable: Encodable, Sendable {
	public let boundingRegion: DocumentRegion
	public let rows: [[DocumentTableCell]]

	public init(boundingRegion: DocumentRegion, rows: [[DocumentTableCell]]) {
		self.boundingRegion = boundingRegion
		self.rows = rows
	}
}

public struct DocumentTableCell: Encodable, Sendable {
	public let rowRange: DocumentIndexRange
	public let columnRange: DocumentIndexRange
	public let content: DocumentContainer

	public init(rowRange: DocumentIndexRange, columnRange: DocumentIndexRange, content: DocumentContainer) {
		self.rowRange = rowRange
		self.columnRange = columnRange
		self.content = content
	}
}

/// Inclusive zero-based range, matching Vision table-cell range semantics.
public struct DocumentIndexRange: Encodable, Sendable {
	public let start: Int
	public let end: Int

	public init(start: Int, end: Int) {
		self.start = start
		self.end = end
	}
}

public struct DocumentList: Encodable, Sendable {
	public let boundingRegion: DocumentRegion
	public let items: [DocumentListItem]

	public init(boundingRegion: DocumentRegion, items: [DocumentListItem]) {
		self.boundingRegion = boundingRegion
		self.items = items
	}
}

public struct DocumentListItem: Encodable, Sendable {
	public let markerType: DocumentListMarker?
	public let markerText: String
	public let text: String
	public let content: DocumentContainer

	public init(markerType: DocumentListMarker?, markerText: String, text: String, content: DocumentContainer) {
		self.markerType = markerType
		self.markerText = markerText
		self.text = text
		self.content = content
	}
}

public enum DocumentListMarker: String, Encodable, Sendable {
	case bullet, hyphen, lowercaseLatin, uppercaseLatin, decimal, decorativeDecimal, compositeDecimal, unknown
}

public struct DocumentRegion: Encodable, Sendable {
	public let points: [DocumentPoint]
	public let boundingBox: BoundingBox

	public init(points: [DocumentPoint], boundingBox: BoundingBox) {
		self.points = points
		self.boundingBox = boundingBox
	}
}

public struct DocumentPoint: Encodable, Sendable {
	public let x: Double
	public let y: Double

	public init(x: Double, y: Double) {
		self.x = x
		self.y = y
	}
}
