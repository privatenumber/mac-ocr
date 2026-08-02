import MacOcrCLI

let arguments = Array(CommandLine.arguments.dropFirst())
let serviceArgument = "--service"

// Internal Node bridge. Handle it before ArgumentParser so it remains absent
// from public help and shell completions.
if arguments == [serviceArgument] {
	try await OCRService.run()
} else {
	await MacOcr.run(arguments: arguments)
}
