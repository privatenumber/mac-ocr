import ArgumentParser
import Darwin
import Foundation
import MacOcrCore

enum MachineErrorKind: String, Codable {
	case usage
	/// Kept for envelope-schema stability (documented, and typed by the Node
	/// wrapper) even though the OCR-only binary currently never emits it.
	case unavailable
	case runtime
	case `internal`
}

struct MachineErrorEnvelope: Codable {
	let schema: String
	let schemaVersion: Int
	let kind: MachineErrorKind
	let code: String
	let message: String
	let exitCode: Int32
	let command: String?
	let requires: String?
}

enum MachineErrorReporter {
	private static let fd: Int32 = 3

	/// Report an error thrown by `parseAsRoot`/`run()`, using ArgumentParser's
	/// exit-code mapping and human-readable message. Clean exits (`--help`,
	/// `--version`, and other `CleanExit`s — exit code 0) emit no envelope; a
	/// usage error carries the actual validation text rather than an opaque
	/// `CommandError` description.
	static func reportThrownError(_ error: Error, command: String) {
		if error is DocumentUnavailableError {
			report(
				kind: .unavailable,
				code: "document_recognition_unavailable",
				message: "Document recognition requires macOS 26 or later",
				exitCode: 1,
				command: command,
				requires: "macOS 26+"
			)
			return
		}
		let exitCode = MacOcr.exitCode(for: error)
		guard exitCode != ExitCode.success else {
			return
		}
		let isUsage = exitCode == ExitCode.validationFailure
		report(
			kind: isUsage ? .usage : .runtime,
			code: isUsage ? "usage_error" : "runtime_error",
			message: MacOcr.message(for: error),
			exitCode: exitCode.rawValue,
			command: command
		)
	}

	static func report(
		kind: MachineErrorKind,
		code: String,
		message: String,
		exitCode: Int32,
		command: String?,
		requires: String? = nil
	) {
		guard getenv("MAC_OCR_ERROR_FORMAT").map({ String(cString: $0) }) == "json" else {
			return
		}
		guard fcntl(fd, F_GETFD) != -1 else {
			return
		}

		let envelope = MachineErrorEnvelope(
			schema: "mac-ocr.error",
			schemaVersion: 1,
			kind: kind,
			code: code,
			message: message,
			exitCode: exitCode,
			command: command,
			requires: requires
		)

		// Sorted keys make the envelope byte-deterministic across runs —
		// plain JSONEncoder key order varies per process, which breaks
		// byte-level consumers (and snapshot tests).
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		guard var data = try? encoder.encode(envelope) else {
			return
		}
		data.append(0x0A)
		data.withUnsafeBytes { buffer in
			guard let baseAddress = buffer.baseAddress else { return }
			var offset = 0
			while offset < buffer.count {
				let written = Darwin.write(fd, baseAddress.advanced(by: offset), buffer.count - offset)
				if written <= 0 {
					return
				}
				offset += written
			}
		}
	}
}
