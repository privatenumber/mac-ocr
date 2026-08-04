import ArgumentParser
import Foundation
import MacOcrCore

public struct OCRCommand: AsyncParsableCommand {
	public static let configuration = CommandConfiguration(
		commandName: "ocr",
		abstract: "Recognize text in images or PDFs using Apple Vision.",
		discussion: """
			The default action: `mac-ocr <files>` runs OCR without naming `ocr`. \
			Run `mac-ocr --help` for the full set of examples (stdin, clipboard, jq).

			# Plain text to stdout (the default)
			mac-ocr receipt.jpg

			# JSON with per-word bounding boxes and confidence
			mac-ocr receipt.jpg --format json

			# Stream a multi-page PDF one JSON object per page
			mac-ocr scan.pdf --format jsonl

			# Restrict recognition to a region (x,y,w,h; top half here)
			mac-ocr poster.jpg --roi 0,0,1,0.5
			"""
	)

	public init() {}

	@OptionGroup var common: OcrCommandOptions

	@OptionGroup var recognition: RecognitionOptions

	@Option(name: .long, help: "Maximum number of text candidates per observation (1-10). Default 1.")
	var maxCandidates: Int = 1

	public func validate() throws {
		guard maxCandidates >= 1 && maxCandidates <= 10 else {
			throw ValidationError("--max-candidates must be between 1 and 10")
		}
	}

	public func run() async throws {
		// Line-buffer stdout so streaming output isn't held up by pipe buffering
		setvbuf(stdout, nil, _IOLBF, 0)

		let sources = resolveImageSources(files: common.files)
		if sources.isEmpty {
			// Bare `mac-ocr` reaches here via the default subcommand; its help
			// must be the ROOT help (usage without the `ocr` token, plus the
			// searchable-pdf/languages subcommand list). Only an explicit
			// `mac-ocr ocr` gets this subcommand's own help.
			if CommandLine.arguments.dropFirst().first == "ocr" {
				throw CleanExit.helpRequest(self)
			}
			throw CleanExit.helpRequest(MacOcr.self)
		}

		let options = try recognition.buildOCROptions(
			regionOfInterest: try common.roi.map(parseRegionOfInterest),
			maxCandidates: maxCandidates
		)
		let outputMode = try common.resolvedOutputMode

		// Show a live page counter on interactive stderr — except when the
		// results themselves are already streaming to the same terminal
		// (text/jsonl to a stdout TTY): there the scrolling output *is* the
		// progress, and a rewriting counter would fight it. File output,
		// redirected stdout, and buffered `--format json` all get the counter.
		let writesToFiles: Bool
		if case .off = outputMode {
			writesToFiles = false
		} else {
			writesToFiles = true
		}
		let streamsToTerminal =
			!writesToFiles && common.format != .json && FileHandle.standardOutput.isTerminal
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
			try await OCREngine.run(session: session, options: options)
		}
		reporter?.finish(outputPath: nil)
	}
}
