import CoreGraphics
import Foundation
import Vision

public struct OCROptions: Sendable {
	public var recognitionLevel: RecognitionLevel = .accurate
	public var languages: [String] = []
	public var usesLanguageCorrection: Bool = true
	public var customWords: [String] = []
	public var minimumTextHeight: Float?
	public var minimumConfidence: Float = 0.0
	/// Restrict recognition to this normalized sub-rectangle (top-left origin,
	/// the same space as output boxes). `nil` means the full image. Flipped to
	/// Vision's bottom-left-origin `regionOfInterest` via `CGRect(_:)`.
	public var regionOfInterest: BoundingBox? = nil
	/// Maximum number of text candidates per observation (1-10). Default 1.
	public var maxCandidates: Int = 1
	/// Compute per-word geometry (`Observation.words`). Off by default — the
	/// `ocr` command's output never includes it, so only the searchable-pdf
	/// path (which positions invisible text per word) pays for the extra
	/// per-word `boundingBox(for:)` calls.
	public var includeWordGeometry: Bool = false

	public enum RecognitionLevel: Sendable {
		case fast, accurate
	}

	public init(
		recognitionLevel: RecognitionLevel = .accurate,
		languages: [String] = [],
		usesLanguageCorrection: Bool = true,
		customWords: [String] = [],
		minimumTextHeight: Float? = nil,
		minimumConfidence: Float = 0.0,
		regionOfInterest: BoundingBox? = nil,
		maxCandidates: Int = 1,
		includeWordGeometry: Bool = false
	) {
		self.recognitionLevel = recognitionLevel
		self.languages = languages
		self.usesLanguageCorrection = usesLanguageCorrection
		self.customWords = customWords
		self.minimumTextHeight = minimumTextHeight
		self.minimumConfidence = minimumConfidence
		self.regionOfInterest = regionOfInterest
		self.maxCandidates = maxCandidates
		self.includeWordGeometry = includeWordGeometry
	}
}

public enum OCRStrategy: String, CaseIterable, Sendable {
	case auto, standard, partitioned
}

public struct OCRResult: ResultPayload {
	public let text: String
	public let observations: [Observation]

	public var textOutput: String { text }

	public init(text: String, observations: [Observation]) {
		self.text = text
		self.observations = observations
	}
}

final class OCRCancellation: @unchecked Sendable {
	private let lock = NSLock()
	private var request: VNRequest?
	private var cancelled = false

	func cancel() {
		let activeRequest = lock.withLock {
			cancelled = true
			return request
		}
		activeRequest?.cancel()
	}

	func checkCancellation() throws {
		let isCancelled = lock.withLock { cancelled }
		if isCancelled || Task.isCancelled {
			throw CancellationError()
		}
	}

	func register(_ request: VNRequest) throws {
		try lock.withLock {
			if cancelled {
				throw CancellationError()
			}
			self.request = request
		}
	}

	func unregister() {
		lock.withLock {
			request = nil
		}
	}
}

public struct TextCandidate: Encodable, Sendable {
	public let text: String
	public let confidence: Float

	public init(text: String, confidence: Float) {
		self.text = text
		self.confidence = confidence
	}
}

/// A single whitespace-separated word within an observation, positioned by
/// Vision's per-range geometry. Not part of the JSON schema — used by the
/// searchable-pdf layer to place one invisible text run per word so selection
/// rectangles track the printed words instead of approximating a whole line.
public struct WordBox: Sendable {
	public let text: String
	public let boundingBox: BoundingBox

	public init(text: String, boundingBox: BoundingBox) {
		self.text = text
		self.boundingBox = boundingBox
	}
}

public struct ObservationSource: Sendable {
	public let pass: String
	public let partition: BoundingBox?
	public let edgeTouching: Bool
	public let depth: Int?

	public init(pass: String, partition: BoundingBox? = nil, edgeTouching: Bool = false, depth: Int? = nil) {
		self.pass = pass
		self.partition = partition
		self.edgeTouching = edgeTouching
		self.depth = depth
	}
}

public struct Observation: Encodable, Sendable {
	public let text: String
	public let confidence: Float
	/// Vision model revision that produced this observation.
	public let requestRevision: Int
	public let boundingBox: BoundingBox
	/// Alternative readings. Populated only when more than one candidate was
	/// requested (`--max-candidates > 1`); empty — and omitted from the JSON —
	/// at the default, where the lone candidate would just duplicate
	/// `text`/`confidence`.
	public let candidates: [TextCandidate]
	/// Per-word geometry for the top candidate. Deliberately excluded from
	/// the encoded schema; empty when Vision couldn't provide ranges.
	public let words: [WordBox]
	/// Internal/debug origin. Deliberately excluded from the normal JSON schema.
	public let source: ObservationSource?

	private enum CodingKeys: String, CodingKey {
		case text, confidence, requestRevision, boundingBox, candidates
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(text, forKey: .text)
		try container.encode(confidence, forKey: .confidence)
		try container.encode(requestRevision, forKey: .requestRevision)
		try container.encode(boundingBox, forKey: .boundingBox)
		if !candidates.isEmpty {
			try container.encode(candidates, forKey: .candidates)
		}
	}

	public init(
		text: String,
		confidence: Float,
		requestRevision: Int,
		boundingBox: BoundingBox,
		candidates: [TextCandidate],
		words: [WordBox] = [],
		source: ObservationSource? = nil
	) {
		self.text = text
		self.confidence = confidence
		self.requestRevision = requestRevision
		self.boundingBox = boundingBox
		self.candidates = candidates
		self.words = words
		self.source = source
	}
}

/// Per-word geometry for a recognized candidate: split the string on
/// whitespace and ask Vision for each token's bounding box. Tokens Vision
/// can't locate are skipped; a fully empty result means callers should fall
/// back to the line-level box.
private func wordBoxes(for candidate: VNRecognizedText) -> [WordBox] {
	let string = candidate.string
	var words: [WordBox] = []
	var index = string.startIndex
	while index < string.endIndex {
		while index < string.endIndex, string[index].isWhitespace {
			index = string.index(after: index)
		}
		guard index < string.endIndex else { break }
		let start = index
		while index < string.endIndex, !string[index].isWhitespace {
			index = string.index(after: index)
		}
		guard let rectangle = try? candidate.boundingBox(for: start..<index) else { continue }
		words.append(
			WordBox(
				text: String(string[start..<index]),
				boundingBox: BoundingBox(rectangle.boundingBox)
			))
	}
	return words
}

public func supportedLanguages(fast: Bool) -> [String] {
	let level: VNRequestTextRecognitionLevel = fast ? .fast : .accurate
	if #available(macOS 13.0, *) {
		let request = VNRecognizeTextRequest()
		request.recognitionLevel = level
		// try? is intentional: supportedRecognitionLanguages() can throw only if
		// Vision's model bundle is corrupted/missing. In that scenario an empty
		// list is the correct defensive return value — the caller uses this for
		// `--list-languages` display, not for a critical data path.
		return (try? request.supportedRecognitionLanguages()) ?? []
	} else if #available(macOS 11.0, *) {
		return
			(try? VNRecognizeTextRequest.supportedRecognitionLanguages(
				for: level,
				revision: VNRecognizeTextRequestRevision2
			)) ?? []
	} else {
		return ["en-US"]
	}
}

/// Recognize text in a prepared `VisionSession`. Taking a session (rather than
/// a raw image) lets the `VNImageRequestHandler` be built once per page and
/// reused across requests on the same image.
///
/// Internal on purpose: external callers must go through `OCREngine.run`,
/// which serializes Vision execution via `VisionRuntime` — the only public
/// recognition entry point.
func recognizeText(
	in session: VisionSession,
	options: OCROptions,
	cancellation: OCRCancellation? = nil
) throws -> OCRResult {
	var recognizedObservations: [Observation] = []
	var recognitionError: Error?
	let candidateCount = max(1, min(options.maxCandidates, 10))

	let request = VNRecognizeTextRequest { request, error in
		if let error {
			recognitionError = error
			return
		}

		guard let results = request.results as? [VNRecognizedTextObservation] else {
			return
		}

		for observation in results {
			guard observation.confidence >= options.minimumConfidence else {
				continue
			}

			let allCandidates = observation.topCandidates(candidateCount)
			guard let top = allCandidates.first else {
				continue
			}

			// At the default (one candidate) the list would just duplicate
			// `text`/`confidence` — only populate it when alternatives were
			// actually requested.
			let candidates =
				candidateCount > 1
				? allCandidates.map { TextCandidate(text: $0.string, confidence: $0.confidence) }
				: []

			recognizedObservations.append(
				Observation(
					text: top.string,
					confidence: observation.confidence,
					requestRevision: observation.requestRevision,
					boundingBox: BoundingBox(observation),
					candidates: candidates,
					words: options.includeWordGeometry ? wordBoxes(for: top) : []
				))
		}
	}

	switch options.recognitionLevel {
	case .fast:
		request.recognitionLevel = .fast
	case .accurate:
		request.recognitionLevel = .accurate
	}

	if !options.languages.isEmpty {
		request.recognitionLanguages = options.languages
	}

	request.usesLanguageCorrection = options.usesLanguageCorrection
	request.customWords = options.customWords

	if let minHeight = options.minimumTextHeight {
		request.minimumTextHeight = minHeight
	}

	if #available(macOS 13.0, *) {
		request.automaticallyDetectsLanguage = options.languages.isEmpty
	}

	if let roi = options.regionOfInterest {
		request.regionOfInterest = CGRect(roi)
	}

	try cancellation?.register(request)
	defer { cancellation?.unregister() }
	do {
		try session.handler.perform([request])
	} catch {
		try cancellation?.checkCancellation()
		throw error
	}
	try cancellation?.checkCancellation()

	if let error = recognitionError {
		throw error
	}

	let fullText = recognizedObservations.map(\.text).joined(separator: "\n")

	return OCRResult(
		text: fullText,
		observations: recognizedObservations
	)
}

// MARK: - OCREngine

/// The async text-recognition entry point: `recognizeText` routed through the
/// serial `VisionRuntime` executor. Use this (never the bare `recognizeText`)
/// whenever multiple async callers may exist.
public enum OCREngine {
	public static func run(
		session: VisionSession,
		options: OCROptions
	) async throws -> OCRResult {
		let cancellation = OCRCancellation()
		return try await withTaskCancellationHandler {
			try cancellation.checkCancellation()
			return try await VisionRuntime.shared.run(session) { session in
				try cancellation.checkCancellation()
				return try recognizeText(in: session, options: options, cancellation: cancellation)
			}
		} onCancel: {
			cancellation.cancel()
		}
	}
}
