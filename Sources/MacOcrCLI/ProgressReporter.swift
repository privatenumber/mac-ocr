import Foundation
import MacOcrCore

/// Short human label for progress output: the input's filename, or the
/// display name for stdin/URL sources.
func progressLabel(for source: ImageSource) -> String {
	let component = (source.displayName as NSString).lastPathComponent
	return component.isEmpty ? source.displayName : component
}

/// Reports per-page progress (and, for `searchable-pdf`, the written output
/// path) on stderr.
///
/// Status is **interactive-only**, following the convention of cp/tar/git:
/// when stderr is not a terminal (a pipe, a file, CI logs) successful runs
/// are completely silent — stderr carries only real errors. There is no
/// `--quiet` flag because piped runs are already quiet, and nobody silences
/// a terminal they are watching.
///
/// All status goes to stderr so stdout stays a clean data channel — `-o -`
/// emits raw PDF bytes and `ocr` streams results, and a status line must
/// never corrupt them.
///
/// Methods run on the caller's task as pages complete, so no synchronization
/// is needed.
final class ProgressReporter {
	private let name: String
	private let interactive: Bool

	init(name: String) {
		self.name = name
		self.interactive = FileHandle.standardError.isTerminal
	}

	/// Live page counter. No-op unless stderr is an interactive terminal.
	func update(done: Int, total: Int) {
		guard interactive else { return }
		// `\r` returns to column 0 to overwrite the previous counter; the
		// trailing clear-to-end-of-line erases leftovers from a longer line.
		fputs("\r\(name)  [\(done)/\(total)]\u{1b}[K", stderr)
		fflush(stderr)
	}

	/// Advisory status for unusually expensive work. No-op unless stderr is an
	/// interactive terminal, matching the live progress behavior above.
	func warning(_ warning: SearchablePDF.Warning) {
		guard interactive else { return }
		fputs("\r\u{1b}[K\(name): \(warning.message)\n", stderr)
		fflush(stderr)
	}

	/// Final status: clears the transient counter, then prints `name → path`
	/// when there is a written path to announce (searchable-pdf file output).
	/// No-op unless stderr is an interactive terminal.
	func finish(outputPath: String?) {
		guard interactive else { return }
		fputs("\r\u{1b}[K", stderr)
		guard let outputPath else { return }
		fputs("\(name) → \(outputPath)\n", stderr)
	}
}
