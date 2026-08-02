import MacOcrCLI

let arguments = Array(CommandLine.arguments.dropFirst())

// Internal Node bridge. Handle it before ArgumentParser so it remains absent
// from public help and shell completions.
if arguments == ["--service"] {
	try await OCRService.run()
} else {
	await MacOcr.run(arguments: arguments)
}
