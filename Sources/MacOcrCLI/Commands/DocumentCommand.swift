import ArgumentParser
import Foundation
import MacOcrCore

public struct DocumentCommand: AsyncParsableCommand {
	public static let configuration = CommandConfiguration(
		commandName: "document",
		abstract: "Extract structured document content from images and PDFs.",
		discussion: """
			Returns paragraphs, tables, lists, and line geometry using macOS 26
			structured document recognition.

			# Print a document transcript
			mac-ocr document receipt.jpg

			# Stream structured JSON for a PDF
			mac-ocr document scan.pdf --format jsonl

			# Write one JSON result per page
			mac-ocr document book.pdf --format json -o '[name]-[page].json'
			"""
	)

	public init() {}

	@OptionGroup var common: OcrCommandOptions
	@OptionGroup var recognition: DocumentRecognitionOptions

	public func validate() throws {
		if common.files.isEmpty && FileHandle.standardInput.isTerminal {
			return
		}
		guard #available(macOS 26.0, *) else {
			return
		}
		_ = try documentOptions()
	}

	public func run() async throws {
		setvbuf(stdout, nil, _IOLBF, 0)

		let sources = resolveImageSources(files: common.files)
		if sources.isEmpty {
			throw CleanExit.helpRequest(self)
		}
		try DocumentEngine.checkAvailability()
		let options = try documentOptions()
		let outputMode = try common.resolvedOutputMode

		let writesToFiles: Bool
		if case .off = outputMode {
			writesToFiles = false
		} else {
			writesToFiles = true
		}
		let streamsToTerminal = !writesToFiles && common.format != .json && FileHandle.standardOutput.isTerminal
		let showProgress = FileHandle.standardError.isTerminal && !streamsToTerminal

		var reporter: ProgressReporter?
		var reporterSourceIndex = -1
		let totalSources = sources.count

		try await BatchRunner.run(
			sources: sources,
			output: .analysis(
				format: common.format,
				outputMode: outputMode,
				totalSources: totalSources
			),
			resolvedPdfDpi: resolvedPdfDpi(common.pdfDpi),
			pdfPassword: resolvePdfPassword(recognition.password),
			onProgress: showProgress
				? { sourceIndex, source, page, pageCount in
					if sourceIndex != reporterSourceIndex {
						reporter?.finish(outputPath: nil)
						reporterSourceIndex = sourceIndex
						let label =
							totalSources > 1
							? "[\(sourceIndex + 1)/\(totalSources)] \(progressLabel(for: source))"
							: progressLabel(for: source)
						reporter = ProgressReporter(name: label)
					}
					reporter?.update(done: page, total: pageCount)
				}
				: nil
		) { session in
			try await DocumentEngine.run(session: session, options: options)
		}
		reporter?.finish(outputPath: nil)
	}

	func documentOptions() throws -> DocumentOptions {
		try DocumentEngine.checkAvailability()
		do {
			return try DocumentEngine.prepare(
				options: recognition.buildDocumentOptions(
					regionOfInterest: try common.roi.map(parseRegionOfInterest)
				)
			)
		} catch let error as DocumentLanguageError {
			throw ValidationError(error.message)
		}
	}
}
