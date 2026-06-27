import Foundation
import MacOcrCore

/// Prints per-page OCR timing to stderr when `MAC_OCR_PROFILE` is set, then a
/// run total. Unlike `ProgressReporter`, this is **not** interactive-only: it
/// is an explicit opt-in measurement, so it prints whether or not stderr is a
/// terminal (it never touches stdout, so `-o -` stays a clean PDF stream).
///
/// Methods run on the caller's task as pages complete, so no synchronization
/// is needed.
final class ProfileReporter {
	private let interactive: Bool
	private var pages = 0
	private var fullPageSeconds = 0.0
	private var partitionSeconds = 0.0
	private var partitionCount = 0
	private var renderSeconds = 0.0
	private var writeSeconds = 0.0

	init() {
		self.interactive = FileHandle.standardError.isTerminal
	}

	private static func seconds(_ value: Double) -> String {
		String(format: "%.2fs", value)
	}

	/// `ProgressReporter` leaves a transient `\r[done/total]` counter (no
	/// newline) on a terminal; clear it first so profile lines start clean.
	/// When stderr is redirected there is no counter, so emit raw lines.
	private func emit(_ line: String) {
		let prefix = interactive ? "\r\u{1b}[K" : ""
		fputs(prefix + line + "\n", stderr)
		fflush(stderr)
	}

	func record(_ record: SearchablePDF.ProfileRecord) {
		pages += 1
		fullPageSeconds += record.fullPageSeconds
		partitionSeconds += record.partitionSeconds
		partitionCount += record.partitionCount
		renderSeconds += record.renderSeconds
		writeSeconds += record.writeSeconds

		let label = (record.source as NSString).lastPathComponent
		let name = label.isEmpty ? record.source : label
		emit(
			"mac-ocr profile  \(name) p\(record.page)/\(record.pageCount)  \(record.strategy)"
				+ "  full=\(Self.seconds(record.fullPageSeconds))"
				+ "  partition=\(Self.seconds(record.partitionSeconds)) (x\(record.partitionCount))"
				+ "  render=\(Self.seconds(record.renderSeconds))"
				+ "  write=\(Self.seconds(record.writeSeconds))"
				+ "  obs=\(record.acceptedObservations)/\(record.rejectedObservations)"
		)
	}

	func finish() {
		guard pages > 0 else { return }
		emit(
			"mac-ocr profile  TOTAL  pages=\(pages)"
				+ "  full=\(Self.seconds(fullPageSeconds))"
				+ "  partition=\(Self.seconds(partitionSeconds)) (x\(partitionCount))"
				+ "  render=\(Self.seconds(renderSeconds))"
				+ "  write=\(Self.seconds(writeSeconds))"
		)
	}
}
