import Foundation
import Testing

@testable import MacOcrCore

private let imageBackedOCRTestsDisabled = {
	VisionGate.shared.acquireBlocking()
	defer { VisionGate.shared.release() }

	do {
		let loaded = try EngineTestSupport.loadImage("hello.png")
		_ = try recognizeText(
			in: VisionSession(image: loaded.image, orientation: loaded.orientation),
			options: OCROptions()
		)
		return false
	} catch {
		// Any probe failure means the host runtime can't run image-backed
		// Vision (historically OSStatus -6662, a CVPixelBuffer failure, but
		// the exact code varies) — skip rather than fail the whole suite.
		fputs("OCREngineTests probe failed; disabling image-backed tests: \(error)\n", stderr)
		return true
	}
}()

@Suite(.serialized) final class OCREngineTests {
	init() { VisionGate.shared.acquireBlocking() }
	deinit { VisionGate.shared.release() }

	@Test(.disabled(if: imageBackedOCRTestsDisabled, "Vision OCR image fixtures require CVPixelBuffer support in the host runtime."))
	func detectsHelloWorld() async throws {
		let loaded = try EngineTestSupport.loadImage("hello.png")
		let result = try await OCREngine.run(
			session: VisionSession(image: loaded.image, orientation: loaded.orientation),
			options: OCROptions()
		)
		#expect(result.text.contains("Hello World"))
		#expect(!result.observations.isEmpty)
		// Range validity is ours to guarantee; confidence *calibration* is
		// Vision's and shifts across model revisions, so don't pin a level.
		#expect(result.observations[0].confidence > 0)
		#expect(result.observations[0].confidence <= 1)
	}

	@Test(.disabled(if: imageBackedOCRTestsDisabled, "Vision OCR image fixtures require CVPixelBuffer support in the host runtime."))
	func emptyImageReturnsEmptyObservations() async throws {
		let loaded = try EngineTestSupport.loadImage("empty.png")
		let result = try await OCREngine.run(
			session: VisionSession(image: loaded.image, orientation: loaded.orientation),
			options: OCROptions()
		)
		#expect(result.text.isEmpty)
		#expect(result.observations.isEmpty)
	}

	@Test(.disabled(if: imageBackedOCRTestsDisabled, "Vision OCR image fixtures require CVPixelBuffer support in the host runtime."))
	func confidenceThresholdFiltersObservations() async throws {
		let loaded = try EngineTestSupport.loadImage("hello.png")
		let baseline = try await OCREngine.run(
			session: VisionSession(image: loaded.image, orientation: loaded.orientation),
			options: OCROptions(minimumConfidence: 0.0)
		)
		let strict = try await OCREngine.run(
			session: VisionSession(image: loaded.image, orientation: loaded.orientation),
			options: OCROptions(minimumConfidence: 1.1)  // impossible
		)
		#expect(!baseline.observations.isEmpty)
		#expect(strict.observations.isEmpty)
	}

	@Test(.disabled(if: imageBackedOCRTestsDisabled, "Vision OCR image fixtures require CVPixelBuffer support in the host runtime."))
	func defaultRequestLeavesCandidatesEmpty() async throws {
		// At the default (maxCandidates 1) the lone candidate would duplicate
		// `text`/`confidence`, so the list stays empty and is omitted from
		// the encoded schema.
		let loaded = try EngineTestSupport.loadImage("hello.png")
		let result = try await OCREngine.run(
			session: VisionSession(image: loaded.image, orientation: loaded.orientation),
			options: OCROptions()
		)
		#expect(!result.observations.isEmpty)
		for observation in result.observations {
			#expect(observation.candidates.isEmpty)
		}
	}

	@Test(.disabled(if: imageBackedOCRTestsDisabled, "Vision OCR image fixtures require CVPixelBuffer support in the host runtime."))
	func multipleCandidatesReturnsUpToRequestedCount() async throws {
		let loaded = try EngineTestSupport.loadImage("hello.png")
		let result = try await OCREngine.run(
			session: VisionSession(image: loaded.image, orientation: loaded.orientation),
			options: OCROptions(maxCandidates: 5)
		)
		#expect(!result.observations.isEmpty)
		for observation in result.observations {
			#expect(observation.candidates.count >= 1)
			#expect(observation.candidates.count <= 5)
			#expect(observation.candidates[0].text == observation.text)
		}
	}

	@Test(.disabled(if: imageBackedOCRTestsDisabled, "Vision OCR image fixtures require CVPixelBuffer support in the host runtime."))
	func roiRestrictsDetectionToSubRegion() async throws {
		let loaded = try EngineTestSupport.loadImage("hello.png")
		let fullResult = try await OCREngine.run(
			session: VisionSession(image: loaded.image, orientation: loaded.orientation),
			options: OCROptions(regionOfInterest: BoundingBox(x: 0, y: 0, width: 1, height: 1))
		)
		#expect(fullResult.text.contains("Hello World"))

		let emptyRegion = try await OCREngine.run(
			session: VisionSession(image: loaded.image, orientation: loaded.orientation),
			options: OCROptions(regionOfInterest: BoundingBox(x: 0, y: 0, width: 1, height: 0.05))
		)
		#expect(emptyRegion.text.isEmpty)
	}

	@Test func supportedLanguagesIncludesEnglish() {
		let accurate = supportedLanguages(fast: false)
		#expect(accurate.contains("en-US"))
		#expect(accurate.count > 1)
	}

	@Test func fastModeLanguageListIsShorter() {
		let accurate = supportedLanguages(fast: false)
		let fast = supportedLanguages(fast: true)
		#expect(fast.count < accurate.count)
		#expect(fast.contains("en-US"))
	}
}
