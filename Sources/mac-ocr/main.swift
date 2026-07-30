import MacOcrCLI

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--service=1"] {
	try await OCRService.run()
} else {
	await MacOcr.run(arguments: arguments)
}
