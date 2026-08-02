import Foundation
import Testing

/// End-to-end checks of the fd-3 machine-error envelope (`MAC_OCR_ERROR_FORMAT=json`).
/// Spawns the binary via `/bin/sh` so fd 3 can be redirected to a file, then
/// inspects what — if anything — was written there.
@Suite(.serialized) struct MachineErrorFd3Tests {

	@Test func helpCleanExitEmitsNoEnvelope() throws {
		let run = try TestSupport.runCapturingFd3(["--help"])
		#expect(run.exitCode == 0)
		#expect(
			run.fd3.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			"A clean --help exit must not emit an error envelope; got fd3: \(run.fd3)"
		)
	}

	@Test func versionCleanExitEmitsNoEnvelope() throws {
		let run = try TestSupport.runCapturingFd3(["--version"])
		#expect(run.exitCode == 0)
		#expect(
			run.fd3.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			"A clean --version exit must not emit an error envelope; got fd3: \(run.fd3)"
		)
	}

	@Test func invalidOptionEmitsUsageEnvelopeWithRealMessage() throws {
		// `--confidence abc` fails to parse as a Float inside ArgumentParser
		// (a CommandError), distinct from our own validate() ValidationErrors.
		let run = try TestSupport.runCapturingFd3(["ocr", "--confidence", "abc"])
		#expect(run.exitCode == 64)

		let envelope = try #require(
			JSONSerialization.jsonObject(with: Data(run.fd3.utf8)) as? [String: Any],
			"Expected a JSON error envelope on fd 3; got: \(run.fd3)"
		)
		#expect(envelope["kind"] as? String == "usage")
		#expect(envelope["code"] as? String == "usage_error")
		#expect(envelope["exitCode"] as? Int == 64)
		let message = (envelope["message"] as? String ?? "").lowercased()
		#expect(
			message.contains("confidence") || message.contains("abc"),
			"Envelope must carry the real usage message, not an opaque error type; got: \(envelope["message"] ?? "")"
		)
	}

	@Test func invalidServiceArgumentUsesNormalUsageError() throws {
		let run = try TestSupport.runCapturingFd3(["--service=1"])
		#expect(run.exitCode == 64)

		let envelope = try #require(
			JSONSerialization.jsonObject(with: Data(run.fd3.utf8)) as? [String: Any],
			"Expected a JSON error envelope on fd 3; got: \(run.fd3)"
		)
		#expect(envelope["kind"] as? String == "usage")
		#expect(envelope["code"] as? String == "usage_error")
	}

	@Test func batchFailureEmitsRuntimeEnvelope() throws {
		// A non-image input fails at decode time; the batch reports it and
		// exits 1 via BatchRunFailure, which must surface as a runtime-kind
		// envelope (this was the one envelope kind with no coverage).
		let run = try TestSupport.runCapturingFd3(["ocr", TestSupport.fixturePath("invalid.txt")])
		#expect(run.exitCode == 1)

		let envelope = try #require(
			JSONSerialization.jsonObject(with: Data(run.fd3.utf8)) as? [String: Any],
			"Expected a JSON error envelope on fd 3; got: \(run.fd3)"
		)
		#expect(envelope["kind"] as? String == "runtime")
		#expect(envelope["code"] as? String == "batch_failed")
		#expect(envelope["exitCode"] as? Int == 1)
		#expect(envelope["command"] as? String == "ocr")
		#expect(envelope["schemaVersion"] as? Int == 1)
	}
}
