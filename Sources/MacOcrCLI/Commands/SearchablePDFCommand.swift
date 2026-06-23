import ArgumentParser
import Foundation
import MacOcrCore

public struct SearchablePDFCommand: AsyncParsableCommand, RunnerOptions {
	public static let configuration = CommandConfiguration(
		commandName: "searchable-pdf",
		abstract: "Create a PDF with an invisible, selectable OCR text layer.",
		discussion: """
			Writes one searchable PDF per input — the output looks identical to the \
			source but its text is selectable and searchable. An image becomes a \
			single page; PDF pages are preserved without re-rasterizing their \
			original content. Inputs are never merged.

			  mac-ocr searchable-pdf scan.pdf                 # writes scan.ocr.pdf
			  mac-ocr searchable-pdf *.pdf                     # writes <name>.ocr.pdf for each
			  mac-ocr searchable-pdf scan.pdf -o out/          # writes out/scan.ocr.pdf
			  mac-ocr searchable-pdf scan.pdf -o '[name]-ocr.pdf'
			  mac-ocr searchable-pdf scan.pdf -o -             # PDF to stdout

			By default each input is written next to it as [name].ocr.pdf. A single \
			fixed path or - (stdout) takes only one input; use a directory or a \
			[name] template for multiple.
			"""
	)

	public init() {}

	@Argument(help: "Image or PDF paths to process. Use - for stdin.")
	var files: [String] = []

	@Option(
		name: [.customShort("o"), .long],
		help: "Output path, [name] template, directory, or - for stdout. Default: [name].ocr.pdf next to each input."
	)
	var output: String?

	@Flag(
		name: .long,
		help: "OCR every page, including pages that already have selectable text (skipped by default). Existing digital text may appear twice in copy/search."
	)
	var ocrAllPages = false

	@Option(
		name: .long,
		help: "Visible image layer quality for image inputs (0.0–1.0). OCR still uses the original full-resolution image. PDF inputs are not recompressed."
	)
	var imageQuality: Double?

	@Option(
		name: .long,
		help: "DPI to use for image input page sizing (36–2400). OCR still uses the original full-resolution image. PDF inputs are unaffected."
	)
	var imagePageDpi: Double?

	@OptionGroup var recognition: RecognitionOptions

	@Option(name: .long, help: "PDF rendering DPI for OCR: 'auto' (default) or an integer 72–600.")
	var pdfDpi: String = "auto"

	@Option(name: .long, help: "Region of interest as x,y,w,h in normalized coordinates (0-1, top-left origin).")
	var roi: String?

	public func validate() throws {
		try validatePdfDpi()
		try imageQuality?.requireUnitInterval(name: "--image-quality")
		try imagePageDpi?.requireDPI(name: "--image-page-dpi")
		if let roi {
			_ = try parseRegionOfInterest(roi)
		}
		// Validate output routing up front so large PDFs/URLs aren't rendered
		// only to fail at write time.
		try validateOutputRouting()
	}

	public func run() async throws {
		let sources = resolveInputSources()
		if sources.isEmpty {
			throw CleanExit.helpRequest(self)
		}
		let options = try recognition.buildOCROptions(regionOfInterest: try resolvedROI())
		let pdfDpi = resolvedPdfDpi
		let pdfPassword = resolvePdfPassword(recognition.password)

		// stdout: a single combined-free input straight to the pipe. Progress is
		// written to stderr only, so the piped PDF bytes are never corrupted.
		if output == "-" {
			let reporter = ProgressReporter(name: progressLabel(for: sources[0]))
			let data = try await SearchablePDF.render(
				source: sources[0], options: options, pdfDpi: pdfDpi, password: pdfPassword,
				ocrAllPages: ocrAllPages,
				imageQuality: imageQuality,
				imagePageDpi: imagePageDpi,
				onProgress: { reporter.update(done: $0, total: $1) }
			)
			FileHandle.standardOutput.write(data)
			reporter.finish(outputPath: nil)
			return
		}

		// Per-input: render each source and write to its resolved path. A failing
		// input is reported and the batch continues (fail-soft, like the OCR
		// path); the run exits non-zero if any input failed.
		let mode = try resolvedOutputMode()
		let errorSink = ErrorSink()
		for (index, source) in sources.enumerated() {
			let label =
				sources.count > 1
				? "[\(index + 1)/\(sources.count)] \(progressLabel(for: source))"
				: progressLabel(for: source)
			let reporter = ProgressReporter(name: label)
			do {
				let data = try await SearchablePDF.render(
					source: source, options: options, pdfDpi: pdfDpi, password: pdfPassword,
					ocrAllPages: ocrAllPages,
					imageQuality: imageQuality,
					imagePageDpi: imagePageDpi,
					onProgress: { reporter.update(done: $0, total: $1) }
				)
				let path = try resolveOutputPath(
					mode: mode,
					sourcePath: outputSourcePath(for: source),
					page: 1,
					pageCount: 1,
					outputExtension: ".pdf"
				)
				try ensureParentDirectory(forFile: path)
				// Atomic: a crash mid-write must not replace a previous good
				// output (e.g. a re-run's [name].ocr.pdf) with a truncated PDF.
				try data.write(to: URL(fileURLWithPath: path), options: .atomic)
				reporter.finish(outputPath: path)
			} catch {
				// ErrorSink clears the transient counter line itself before
				// printing, so the error never appends to it.
				await errorSink.report(error)
			}
		}
		if await errorSink.hadError {
			throw BatchRunFailure()
		}
	}

	/// The per-input output mode. The default and directory forms resolve to a
	/// `[name].ocr.pdf` template (replace-extension naming); `[…]` templates pass
	/// through; a bare path is a single static file. (`-o -` for stdout is
	/// handled separately.)
	private func resolvedOutputMode() throws -> OutputMode {
		guard let output else {
			return .template(try OutputTemplate(template: "[dir]/[name].ocr.pdf"))
		}
		switch try parseOutputValue(output) {
		case .directory(let directory):
			let base = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
			return .template(try OutputTemplate(template: "\(base)/[name].ocr.pdf"))
		case let mode:
			return mode
		}
	}

	private func validateOutputRouting() throws {
		let multipleInputs = resolveInputSources().count > 1

		if output == "-" {
			if multipleInputs {
				throw ValidationError(
					"`-o -` writes one PDF to stdout and takes a single input. For multiple inputs use a directory (e.g. -o out/) or a [name] template (e.g. -o '[name].ocr.pdf')."
				)
			}
			if FileHandle.standardOutput.isTerminal {
				throw ValidationError(
					"Refusing to write a PDF to the terminal. Pass -o <file.pdf>, -o <dir>/, or redirect stdout (-o -)."
				)
			}
			return
		}

		let mode: OutputMode
		do {
			mode = try resolvedOutputMode()
		} catch let error as MessageError {
			throw ValidationError(error.message)
		}

		if case .static = mode, multipleInputs {
			throw ValidationError(
				"A single output path can't hold multiple inputs. Use a directory (e.g. -o out/) or a [name] template (e.g. -o '[name].ocr.pdf')."
			)
		}
		try validateOutputModeSupportsSources(mode, files: files)
		try validateNoOutputCollisions(mode: mode)
	}

	/// Reject input sets where two sources resolve to the same output path.
	/// Each input is written to its own PDF, so a collision would silently
	/// overwrite an earlier result. The OCR analysis path guards the same way;
	/// running this in `validate()` fails fast (exit 64) before any rendering
	/// rather than losing data mid-batch.
	private func validateNoOutputCollisions(mode: OutputMode) throws {
		let sources = resolveInputSources()
		guard sources.count > 1 else { return }

		var seen: [String: ImageSource] = [:]
		for source in sources {
			let path: String
			do {
				path = try resolveOutputPath(
					mode: mode,
					sourcePath: outputSourcePath(for: source),
					page: 1,
					pageCount: 1,
					outputExtension: ".pdf"
				)
			} catch let error as MessageError {
				throw ValidationError(error.message)
			}
			if let previous = seen[path] {
				throw ValidationError(
					"'\(previous.displayName)' and '\(source.displayName)' both resolve to the same output '\(path)'. "
						+ "Searchable PDFs are written one per input and would overwrite each other — give them distinct outputs "
						+ "(e.g. process each directory separately, or use a fixed -o path for a single input)."
				)
			}
			seen[path] = source
		}
	}

}
