import ArgumentParser
import Foundation
import MacOcrCore

/// Recognition controls supported by `RecognizeDocumentsRequest`. This request
/// has no fast mode and does not share `RecognitionOptions` intentionally.
struct DocumentRecognitionOptions: ParsableArguments {
	@Option(name: .long, help: "Password for an encrypted PDF (or set MAC_OCR_PDF_PASSWORD).")
	var password: String?

	@Option(name: .shortAndLong, help: "Recognition language (repeatable). Example: en")
	var language: [String] = []

	@Option(name: [.customShort("w"), .long], help: "Custom vocabulary word (repeatable).")
	var customWords: [String] = []

	@Option(name: .long, help: "File with custom vocabulary words (one per line).")
	var customWordsFile: String?

	@Flag(name: .long, help: "Disable language correction.")
	var noLanguageCorrection = false

	@Option(name: .long, help: "Minimum text height relative to image (0.0-1.0).")
	var minTextHeight: Float?

	@Option(name: .long, help: "Maximum text candidates per line (1-10). Default 1.")
	var maxCandidates = 1

	func validate() throws {
		if let minTextHeight {
			try minTextHeight.requireUnitInterval(name: "--min-text-height")
		}
		guard maxCandidates >= 1 && maxCandidates <= 10 else {
			throw ValidationError("--max-candidates must be between 1 and 10")
		}
		if let customWordsFile {
			var isDirectory = ObjCBool(false)
			let exists = FileManager.default.fileExists(atPath: customWordsFile, isDirectory: &isDirectory)
			guard exists, !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: customWordsFile) else {
				throw ValidationError("Cannot read --custom-words-file: \(customWordsFile)")
			}
		}
	}

	func buildDocumentOptions(regionOfInterest: BoundingBox?) throws -> DocumentOptions {
		var allCustomWords = customWords
		if let filePath = customWordsFile {
			let content = try String(contentsOfFile: filePath, encoding: .utf8)
			allCustomWords.append(contentsOf: content.split(separator: "\n").map(String.init).filter { !$0.isEmpty })
		}

		return DocumentOptions(
			languages: language,
			usesLanguageCorrection: !noLanguageCorrection,
			customWords: allCustomWords,
			minimumTextHeight: minTextHeight,
			maxCandidates: maxCandidates,
			regionOfInterest: regionOfInterest
		)
	}
}
