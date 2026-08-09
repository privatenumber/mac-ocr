import Foundation
import Testing

/// Help routing for the default subcommand: a bare `mac-ocr` on a terminal
/// must print the ROOT help (usage without the `ocr` token + the subcommand
/// list), while an explicit `mac-ocr ocr` gets the subcommand's own help.
/// Regression: the empty-input branch used to throw `helpRequest(self)`
/// unconditionally, so bare invocations showed "USAGE: mac-ocr ocr …" and
/// never mentioned `searchable-pdf`.
@Suite(.serialized) struct DefaultHelpTests {

	@Test func bareInvocationShowsRootHelp() throws {
		let result = try runWithTerminalStdin([])
		#expect(result.exitCode == 0)
		#expect(result.stdout.contains("document"))
		#expect(result.stdout.contains("searchable-pdf"), "root help must list subcommands; got: \(result.stdout)")
		#expect(result.stdout.contains("languages"))
		#expect(!result.stdout.contains("--service"), "internal service switch leaked into help: \(result.stdout)")
		#expect(
			!result.stdout.contains("USAGE: mac-ocr ocr"),
			"bare invocation must not show the ocr subcommand usage; got: \(result.stdout)"
		)
	}

	@Test func explicitOcrInvocationShowsOcrHelp() throws {
		let result = try runWithTerminalStdin(["ocr"])
		#expect(result.exitCode == 0)
		#expect(result.stdout.contains("USAGE: mac-ocr ocr"), "got: \(result.stdout)")
		#expect(!result.stdout.contains("--service"), "internal service switch leaked into help: \(result.stdout)")
	}

	@Test func explicitDocumentInvocationShowsDocumentHelp() throws {
		let result = try runWithTerminalStdin(["document"])
		#expect(result.exitCode == 0)
		#expect(result.stdout.contains("USAGE: mac-ocr document"), "got: \(result.stdout)")
	}

	// MARK: - Helper

	/// Run the binary with stdin attached to a pseudo-terminal so the
	/// no-files-and-stdin-is-a-TTY branch (help, rather than reading stdin)
	/// is taken.
	private func runWithTerminalStdin(
		_ args: [String]
	) throws -> (exitCode: Int32, stdout: String) {
		let pty = try PTYSupport.open()

		let process = Process()
		process.executableURL = TestSupport.binaryURL
		process.arguments = args
		process.standardInput = FileHandle(fileDescriptor: pty.slave, closeOnDealloc: true)
		let outPipe = Pipe()
		process.standardOutput = outPipe
		process.standardError = FileHandle.nullDevice

		// Drain the master end so the child never blocks on the pty.
		let masterHandle = FileHandle(fileDescriptor: pty.master, closeOnDealloc: true)
		DispatchQueue.global().async { _ = masterHandle.readDataToEndOfFile() }

		try process.run()
		let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()

		return (process.terminationStatus, String(data: stdoutData, encoding: .utf8) ?? "")
	}
}
