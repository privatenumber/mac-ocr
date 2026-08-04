import ArgumentParser
import Foundation
import MacOcrCore

extension OutputFormat: ExpressibleByArgument {}

/// The `ocr` command's own arguments (inputs, format, output routing).
/// `searchable-pdf` declares its own input/output surface because the
/// semantics differ (one PDF artifact per input, `-o -`, no `--format`);
/// the flags the two commands genuinely share live in `RecognitionOptions`.
struct OcrCommandOptions: ParsableArguments {
	@Argument(help: "Image or PDF paths to process. Use - for stdin.")
	var files: [String] = []

	@Option(name: .shortAndLong, help: "Output format: text, json, jsonl. Text and jsonl stream; json buffers a single array.")
	var format: OutputFormat = .text

	/// `-o <path>` / `--output <path>` — write to a path, directory, or template.
	///
	/// Disambiguation rules (applied in order):
	/// 1. Contains `[placeholder]` syntax → **template** mode
	/// 2. Ends with `/` or names an existing directory → **directory** mode
	/// 3. Otherwise → **static** path (single-input only)
	///
	/// Available template placeholders: `[name]`, `[ext]`, `[page]`, `[pagecount]`, `[dir]`.
	@Option(
		name: [.customShort("o"), .customLong("output")],
		help: "Output destination. Existing dir or dir/ → directory; [name] placeholders → template; otherwise fixed file."
	)
	var output: String?

	@Option(name: .long, help: "PDF rendering DPI: 'auto' (default, derived from embedded image resolution; falls back to 144) or an integer 72–600.")
	var pdfDpi: String = "auto"

	@Option(name: .long, help: "Region of interest as x,y,w,h in normalized coordinates (0-1, top-left origin). Example: 0,0,1,0.5 for the top half.")
	var roi: String? = nil

	/// Resolved output mode derived from `-o` / `--output`.
	var resolvedOutputMode: OutputMode {
		get throws {
			guard let output else { return .off }
			return try parseOutputValue(output)
		}
	}

	func validate() throws {
		try validatePdfDpi(pdfDpi)
		if let roi {
			_ = try parseRegionOfInterest(roi)
		}
		// Two foot-guns, caught before any work:
		// `-o -` — ocr already streams to stdout; the flag would create a
		// file literally named "-". `-o *.pdf` — ocr writes recognized text
		// (or JSON), so the output would be a text file wearing a .pdf name;
		// the user almost certainly wants the searchable-pdf subcommand.
		if let output {
			if output == "-" {
				throw ValidationError(
					"ocr already writes results to stdout — omit -o. (To stream a searchable PDF to stdout, use `mac-ocr searchable-pdf -o -`.)")
			}
			if output.lowercased().hasSuffix(".pdf") {
				throw ValidationError(
					"ocr writes recognized text (or JSON), so '\(output)' would be a plain-text file with a .pdf name. To produce a searchable PDF, use `mac-ocr searchable-pdf`; otherwise pick a different extension."
				)
			}
		}
		try validateOutputModeSupportsSources(try resolvedOutputMode, files: files)
	}
}
