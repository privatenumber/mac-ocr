import ArgumentParser
import Darwin
import Foundation
import MacOcrCore

public struct MacOcr: AsyncParsableCommand {
	public static let configuration = CommandConfiguration(
		commandName: "mac-ocr",
		abstract: "Recognize text in images and PDFs using Apple Vision.",
		discussion: """
			OCR is the default action, so no subcommand is needed.

			# Read text from an image
			mac-ocr receipt.jpg

			# OCR several files at once (images and/or PDFs)
			mac-ocr *.png invoice.pdf

			# Read from stdin: a screenshot, scan, or download
			cat screenshot.png | mac-ocr
			curl -sL https://example.com/sign.png | mac-ocr

			# Copy the recognized text to the clipboard
			mac-ocr receipt.jpg | pbcopy

			# Stream a large PDF page by page (JSON Lines)
			mac-ocr book.pdf --format jsonl

			# Bounding boxes and confidence as JSON, queried with jq
			mac-ocr receipt.jpg --format json | jq '.[0].observations[].text'

			# Save each file's text alongside it as .txt
			mac-ocr ~/Screenshots/*.png -o '[dir]/[name].txt'

			# Recognize specific languages (repeatable, BCP-47)
			mac-ocr menu.jpg -l ja-JP -l en-US

			Other actions: `document` extracts structured content on macOS 26+; \
			`searchable-pdf` adds a selectable text layer to a PDF or image; \
			`languages` lists supported ordinary-OCR recognition languages. Run \
			`mac-ocr <subcommand> --help` for details.
			""",
		version: macOcrVersion,
		subcommands: [
			OCRCommand.self,
			DocumentCommand.self,
			SearchablePDFCommand.self,
			LanguagesCommand.self,
		],
		defaultSubcommand: OCRCommand.self
	)

	public init() {}

	public static func run(arguments: [String]) async {
		await runParsedCommand(arguments)
	}
}

// Subcommand names known to this build. Used only to attribute machine-error
// envelopes to the right command. Derived at runtime from the configured
// subcommands so it never drifts out of sync.
private let knownSubcommands: Set<String> = {
	var names = Set(MacOcr.configuration.subcommands.map { $0._commandName })
	for subcommand in MacOcr.configuration.subcommands {
		for alias in subcommand.configuration.aliases {
			names.insert(alias)
		}
	}
	return names
}()

private func machineCommandName(_ arguments: [String]) -> String {
	guard let command = arguments.first, knownSubcommands.contains(command) else {
		return OCRCommand.configuration.commandName ?? "ocr"
	}
	return command
}

private func runParsedCommand(_ arguments: [String]) async {
	let commandName = machineCommandName(arguments)
	do {
		var command = try MacOcr.parseAsRoot(arguments)
		if var asyncCommand = command as? AsyncParsableCommand {
			try await asyncCommand.run()
		} else {
			try command.run()
		}
	} catch let error as UsageError {
		MachineErrorReporter.report(
			kind: .usage,
			code: "usage_error",
			message: error.message,
			exitCode: 64,
			command: commandName
		)
		MacOcr.exit(withError: ValidationError(error.message))
	} catch let error as ValidationError {
		MachineErrorReporter.report(
			kind: .usage,
			code: "usage_error",
			message: error.message,
			exitCode: 64,
			command: commandName
		)
		MacOcr.exit(withError: error)
	} catch let error as BatchRunFailure {
		MachineErrorReporter.report(
			kind: .runtime,
			code: "batch_failed",
			message: "one or more inputs failed",
			exitCode: error.code,
			command: commandName
		)
		exit(error.code)
	} catch {
		// Includes ArgumentParser clean exits (--help/--version → no envelope,
		// exit 0) and parse/usage errors (real message, exit 64).
		MachineErrorReporter.reportThrownError(error, command: commandName)
		MacOcr.exit(withError: error)
	}
}
