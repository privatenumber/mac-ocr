import ArgumentParser
import Darwin
import Foundation
import MacOcrCore

private let serviceMaxFrameBytes = 64 * 1024 * 1024
private let serviceInputDirectoryPrefix = "mac-ocr-service-"
private let serviceParentPollNanoseconds: UInt64 = 250_000_000
private let serviceParentCleanupGraceNanoseconds: UInt64 = 2_000_000_000
private let serviceParentCleanupAttempts = 30
private let serviceParentCleanupRetryNanoseconds: UInt64 = 100_000_000

private struct ServiceHello: Encodable {
	let type = "hello"
	let inputDirectory: String
}

private struct ServiceRequest: Decodable, Sendable {
	let id: UInt32
	let operation: String?
	let command: String?
	let inputName: String?
	let arguments: [String]?
	let password: String?
	let outputName: String?
}

private struct ServiceError: Encodable {
	let kind: String
	let code: String?
	let message: String
	let exitCode: Int32?
	let stderr: String
}

private struct ServiceInputUsageError: LocalizedError {
	let errorDescription: String?
}

private struct ServicePageResult<Payload: ResultPayload>: Encodable {
	let page: Int
	let pageCount: Int
	let width: Int
	let height: Int
	let payload: Payload

	private enum CommonKeys: String, CodingKey {
		case page, pageCount, width, height
	}

	func encode(to encoder: Encoder) throws {
		try payload.encode(to: encoder)
		var container = encoder.container(keyedBy: CommonKeys.self)
		try container.encode(page, forKey: .page)
		try container.encode(pageCount, forKey: .pageCount)
		try container.encode(width, forKey: .width)
		try container.encode(height, forKey: .height)
	}
}

private struct ServiceArtifact: Encodable {
	let name: String
	let size: Int
}

private struct ServiceItem<Result: Encodable>: Encodable {
	let id: UInt32
	let type = "item"
	let sequence: Int
	let result: Result
}

private struct ServiceComplete<Result: Encodable>: Encodable {
	let id: UInt32
	let type = "complete"
	let result: Result?
}

private struct ServiceErrorResponse: Encodable {
	let id: UInt32
	let type = "error"
	let error: ServiceError
}

private final class ServiceResponseControl: @unchecked Sendable {
	private let lock = NSLock()
	private var enabled = true

	func suppress() {
		lock.withLock {
			enabled = false
		}
	}

	func write<Value: Encodable>(_ response: Value) throws {
		try lock.withLock {
			if enabled {
				try writeServiceFrame(response)
			}
		}
	}
}

private actor ServiceCredits {
	private var available = 0
	private var waiter: CheckedContinuation<Void, Never>?
	private var cancelled = false

	func pull() {
		guard !cancelled else { return }
		if let waiter {
			self.waiter = nil
			waiter.resume()
			return
		}
		available += 1
	}

	func wait() async throws {
		guard !cancelled else {
			throw CancellationError()
		}
		try Task.checkCancellation()
		if available > 0 {
			available -= 1
			return
		}
		await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				if cancelled {
					continuation.resume()
					return
				}
				waiter = continuation
			}
		} onCancel: {
			Task { await self.cancel() }
		}
		guard !cancelled else {
			throw CancellationError()
		}
		try Task.checkCancellation()
	}

	func cancel() {
		cancelled = true
		waiter?.resume()
		waiter = nil
	}
}

private func readServiceData(count: Int) throws -> Data? {
	var data = Data()
	while data.count < count {
		let chunk: Data
		if #available(macOS 10.15.4, *) {
			chunk = try FileHandle.standardInput.read(upToCount: count - data.count) ?? Data()
		} else {
			chunk = FileHandle.standardInput.readData(ofLength: count - data.count)
		}
		if chunk.isEmpty {
			return data.isEmpty ? nil : data
		}
		data.append(chunk)
	}
	return data
}

private func readServiceFrame() throws -> Data? {
	guard let header = try readServiceData(count: 4) else { return nil }
	guard header.count == 4 else {
		throw MessageError("Incomplete service frame header")
	}
	let length = header.withUnsafeBytes { buffer in
		UInt32(littleEndian: buffer.loadUnaligned(as: UInt32.self))
	}
	guard length <= serviceMaxFrameBytes else {
		throw MessageError("Service frame exceeds the 64 MiB limit")
	}
	guard let payload = try readServiceData(count: Int(length)), payload.count == Int(length) else {
		throw MessageError("Incomplete service frame payload")
	}
	return payload
}

private func writeServiceFrame<Value: Encodable>(_ value: Value) throws {
	let encoder = JSONEncoder()
	encoder.outputFormatting = [.sortedKeys]
	let payload = try encoder.encode(value)
	guard payload.count <= serviceMaxFrameBytes else {
		throw MessageError("Service response exceeds the 64 MiB limit")
	}
	var length = UInt32(payload.count).littleEndian
	let header = withUnsafeBytes(of: &length) { Data($0) }
	FileHandle.standardOutput.write(header + payload)
}

private func cleanStaleServiceInputDirectories() {
	let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
	guard
		let entries = try? FileManager.default.contentsOfDirectory(
			at: temporaryDirectory,
			includingPropertiesForKeys: [.isDirectoryKey],
			options: [.skipsHiddenFiles]
		)
	else { return }
	for entry in entries where entry.lastPathComponent.hasPrefix(serviceInputDirectoryPrefix) {
		let suffix = entry.lastPathComponent.dropFirst(serviceInputDirectoryPrefix.count)
		let components = suffix.split(separator: "-", maxSplits: 1)
		guard components.count == 2,
			let owner = pid_t(components[0]),
			UUID(uuidString: String(components[1])) != nil,
			owner != getpid(),
			kill(owner, 0) == -1,
			errno == ESRCH,
			(try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
		else { continue }
		try? FileManager.default.removeItem(at: entry)
	}
}

private func monitorServiceParent(_ parent: pid_t, inputDirectory: URL) {
	Task.detached(priority: .background) {
		while getppid() == parent {
			try? await Task.sleep(nanoseconds: serviceParentPollNanoseconds)
		}
		// Give stdin EOF time to cancel active Vision work and run normal defers.
		try? await Task.sleep(nanoseconds: serviceParentCleanupGraceNanoseconds)
		for _ in 0..<serviceParentCleanupAttempts {
			if !FileManager.default.fileExists(atPath: inputDirectory.path) {
				Darwin.exit(1)
			}
			do {
				try FileManager.default.removeItem(at: inputDirectory)
				Darwin.exit(1)
			} catch {
				try? await Task.sleep(nanoseconds: serviceParentCleanupRetryNanoseconds)
			}
		}
		try? FileManager.default.removeItem(at: inputDirectory)
		Darwin.exit(1)
	}
}

private func serviceInputPath(request: ServiceRequest, inputDirectory: URL) throws -> String {
	guard let inputName = request.inputName, UUID(uuidString: inputName) != nil else {
		throw UsageError("Invalid service input name")
	}
	return inputDirectory.appendingPathComponent(inputName, isDirectory: false).path
}

private func serviceOutputPath(request: ServiceRequest, inputDirectory: URL) throws -> String {
	guard let outputName = request.outputName, UUID(uuidString: outputName) != nil else {
		throw UsageError("Invalid service output name")
	}
	return inputDirectory.appendingPathComponent(outputName, isDirectory: false).path
}

private func serviceResult(
	loader: ImageLoader,
	pageIndex: Int,
	options: OCROptions
) async throws -> ServicePageResult<OCRResult> {
	try Task.checkCancellation()
	let loaded = try loader.load(pageIndex)
	try Task.checkCancellation()
	let result = try await OCREngine.run(
		session: VisionSession(image: loaded.image, orientation: loaded.orientation),
		options: options
	)
	return ServicePageResult(
		page: pageIndex + 1,
		pageCount: loader.count,
		width: loaded.displayWidth,
		height: loaded.displayHeight,
		payload: result
	)
}

private func serviceOcrCommand(request: ServiceRequest, inputPath: String) throws -> OCRCommand {
	guard let arguments = request.arguments else {
		throw UsageError("Missing service request arguments")
	}
	return try OCRCommand.parse(arguments + [inputPath])
}

private func serviceDocumentCommand(request: ServiceRequest, inputPath: String) throws -> DocumentCommand {
	guard let arguments = request.arguments else {
		throw UsageError("Missing service request arguments")
	}
	return try DocumentCommand.parse(arguments + [inputPath])
}

private func serviceDocumentResult(
	loader: ImageLoader,
	pageIndex: Int,
	options: DocumentOptions
) async throws -> ServicePageResult<DocumentResult> {
	try Task.checkCancellation()
	let loaded = try loader.load(pageIndex)
	try Task.checkCancellation()
	let result = try await DocumentEngine.run(
		session: VisionSession(image: loaded.image, orientation: loaded.orientation),
		options: options
	)
	return ServicePageResult(
		page: pageIndex + 1,
		pageCount: loader.count,
		width: loaded.displayWidth,
		height: loaded.displayHeight,
		payload: result
	)
}

private func serviceUsageError(
	_ errorMessage: String,
	command: ParsableCommand.Type
) -> ServiceError {
	let commandName = command.configuration.commandName ?? "mac-ocr"
	let message = """
		\(errorMessage)
		Usage: \(MacOcr.usageString(for: command))
		  See 'mac-ocr \(commandName) --help' for more information.
		"""
	return ServiceError(
		kind: "usage",
		code: "usage_error",
		message: message,
		exitCode: 64,
		stderr: "Error: \(message)"
	)
}

private func serviceError(
	_ error: Error,
	inputPath: String?,
	command: ParsableCommand.Type
) -> ServiceError {
	let commandName = command.configuration.commandName ?? "mac-ocr"
	if error is DocumentUnavailableError {
		let message = "Document recognition requires macOS 26 or later"
		return ServiceError(
			kind: "unavailable",
			code: "document_recognition_unavailable",
			message: message,
			exitCode: 1,
			stderr: "Error: \(message)"
		)
	}
	if error is CancellationError {
		return ServiceError(
			kind: "abort",
			code: nil,
			message: "mac-ocr \(commandName) was aborted",
			exitCode: nil,
			stderr: ""
		)
	}
	if let error = error as? ValidationError {
		return serviceUsageError(error.message, command: command)
	}
	if let error = error as? UsageError {
		return serviceUsageError(error.message, command: command)
	}
	if let error = error as? ServiceInputUsageError {
		let message = error.localizedDescription
		return ServiceError(
			kind: "usage",
			code: nil,
			message: message,
			exitCode: nil,
			stderr: ""
		)
	}
	let argumentParserExitCode = MacOcr.exitCode(for: error)
	if argumentParserExitCode == .validationFailure {
		return serviceUsageError(MacOcr.message(for: error), command: command)
	}
	let message =
		inputPath.map {
			error.localizedDescription.replacingOccurrences(of: $0, with: "stdin")
		} ?? error.localizedDescription
	return ServiceError(
		kind: "runtime",
		code: "batch_failed",
		message: message,
		exitCode: 1,
		stderr: "Error: \(message)"
	)
}

private func processServiceOcr(
	request: ServiceRequest,
	inputDirectory: URL,
	responseControl: ServiceResponseControl
) async throws {
	let inputPath = try? serviceInputPath(request: request, inputDirectory: inputDirectory)
	do {
		guard let inputPath else {
			throw UsageError("Invalid service input name")
		}
		defer { try? FileManager.default.removeItem(atPath: inputPath) }
		let command = try serviceOcrCommand(request: request, inputPath: inputPath)
		let options = try command.recognition.buildOCROptions(
			regionOfInterest: try command.common.roi.map(parseRegionOfInterest),
			maxCandidates: command.maxCandidates
		)
		try Task.checkCancellation()
		let loader = try await openSource(
			.file(inputPath),
			pdfDpi: resolvedPdfDpi(command.common.pdfDpi),
			pdfPassword: request.password
		)
		try Task.checkCancellation()
		guard loader.count == 1 else {
			throw ServiceInputUsageError(
				errorDescription: "Input has multiple pages. Use `ocr.pages()` to read them all."
			)
		}
		let result = try await serviceResult(loader: loader, pageIndex: 0, options: options)
		try responseControl.write(ServiceComplete(id: request.id, result: result))
	} catch {
		try responseControl.write(
			ServiceErrorResponse(
				id: request.id,
				error: serviceError(error, inputPath: inputPath, command: OCRCommand.self)
			))
	}
}

private func processServicePages(
	request: ServiceRequest,
	inputDirectory: URL,
	responseControl: ServiceResponseControl,
	credits: ServiceCredits
) async throws {
	let inputPath = try? serviceInputPath(request: request, inputDirectory: inputDirectory)
	do {
		guard let inputPath else {
			throw UsageError("Invalid service input name")
		}
		defer { try? FileManager.default.removeItem(atPath: inputPath) }
		let command = try serviceOcrCommand(request: request, inputPath: inputPath)
		let options = try command.recognition.buildOCROptions(
			regionOfInterest: try command.common.roi.map(parseRegionOfInterest),
			maxCandidates: command.maxCandidates
		)
		try Task.checkCancellation()
		let loader = try await openSource(
			.file(inputPath),
			pdfDpi: resolvedPdfDpi(command.common.pdfDpi),
			pdfPassword: request.password
		)
		try Task.checkCancellation()
		for pageIndex in 0..<loader.count {
			try await credits.wait()
			let result = try await serviceResult(loader: loader, pageIndex: pageIndex, options: options)
			try responseControl.write(
				ServiceItem(
					id: request.id,
					sequence: pageIndex,
					result: result
				))
		}
		try responseControl.write(ServiceComplete<ServicePageResult<OCRResult>>(id: request.id, result: nil))
	} catch {
		try responseControl.write(
			ServiceErrorResponse(
				id: request.id,
				error: serviceError(error, inputPath: inputPath, command: OCRCommand.self)
			))
	}
}

private func processServiceDocument(
	request: ServiceRequest,
	inputDirectory: URL,
	responseControl: ServiceResponseControl,
	credits: ServiceCredits? = nil
) async throws {
	let inputPath = try? serviceInputPath(request: request, inputDirectory: inputDirectory)
	do {
		guard let inputPath else {
			throw UsageError("Invalid service input name")
		}
		defer { try? FileManager.default.removeItem(atPath: inputPath) }
		let command = try serviceDocumentCommand(request: request, inputPath: inputPath)
		let options = try command.documentOptions()
		try Task.checkCancellation()
		let loader = try await openSource(
			.file(inputPath),
			pdfDpi: resolvedPdfDpi(command.common.pdfDpi),
			pdfPassword: request.password
		)
		try Task.checkCancellation()
		if let credits {
			for pageIndex in 0..<loader.count {
				try await credits.wait()
				let result = try await serviceDocumentResult(loader: loader, pageIndex: pageIndex, options: options)
				try responseControl.write(
					ServiceItem(
						id: request.id,
						sequence: pageIndex,
						result: result
					))
			}
			try responseControl.write(ServiceComplete<ServicePageResult<DocumentResult>>(id: request.id, result: nil))
			return
		}
		guard loader.count == 1 else {
			throw ServiceInputUsageError(
				errorDescription: "Input has multiple pages. Use `ocrDocument.pages()` to read them all."
			)
		}
		let result = try await serviceDocumentResult(loader: loader, pageIndex: 0, options: options)
		try responseControl.write(ServiceComplete(id: request.id, result: result))
	} catch {
		try responseControl.write(
			ServiceErrorResponse(
				id: request.id,
				error: serviceError(error, inputPath: inputPath, command: DocumentCommand.self)
			))
	}
}

private func processSearchablePDF(
	request: ServiceRequest,
	inputDirectory: URL,
	responseControl: ServiceResponseControl
) async throws {
	let inputPath = try? serviceInputPath(request: request, inputDirectory: inputDirectory)
	let outputPath = try? serviceOutputPath(request: request, inputDirectory: inputDirectory)
	do {
		guard let inputPath, let outputPath, let outputName = request.outputName else {
			throw UsageError("Invalid service input or output name")
		}
		defer { try? FileManager.default.removeItem(atPath: inputPath) }
		var completed = false
		defer {
			if !completed {
				try? FileManager.default.removeItem(atPath: outputPath)
			}
		}
		guard let arguments = request.arguments else {
			throw UsageError("Missing service request arguments")
		}
		let command = try SearchablePDFCommand.parse(arguments + [inputPath, "-o", outputPath])
		let options = try command.recognition.buildOCROptions(
			regionOfInterest: try command.roi.map(parseRegionOfInterest)
		)
		try Task.checkCancellation()
		let data = try await SearchablePDF.render(
			source: .file(inputPath),
			options: options,
			pdfDpi: MacOcrCLI.resolvedPdfDpi(command.pdfDpi),
			password: request.password,
			ocrAllPages: command.ocrAllPages,
			imageQuality: command.imageQuality,
			imagePageDpi: command.imagePageDpi,
			imageDownsampleDpi: command.imageDownsampleDpi,
			ocrStrategy: command.ocrStrategy
		)
		try Task.checkCancellation()
		try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
		completed = true
		try responseControl.write(
			ServiceComplete(
				id: request.id,
				result: ServiceArtifact(name: outputName, size: data.count)
			))
	} catch {
		try responseControl.write(
			ServiceErrorResponse(
				id: request.id,
				error: serviceError(error, inputPath: inputPath, command: SearchablePDFCommand.self)
			))
	}
}

private func processLanguages(
	request: ServiceRequest,
	responseControl: ServiceResponseControl
) throws {
	do {
		let command = try LanguagesCommand.parse(request.arguments ?? [])
		try responseControl.write(
			ServiceComplete(
				id: request.id,
				result: supportedLanguages(fast: command.fast)
			))
	} catch {
		try responseControl.write(
			ServiceErrorResponse(
				id: request.id,
				error: serviceError(error, inputPath: nil, command: LanguagesCommand.self)
			))
	}
}

private func terminateService(_ error: Error) -> Never {
	let message = "Error: mac-ocr service failed: \(error.localizedDescription)\n"
	FileHandle.standardError.write(Data(message.utf8))
	Darwin.exit(1)
}

public enum OCRService {
	public static func run() async throws {
		cleanStaleServiceInputDirectories()
		// A replacement can start before a killed predecessor's PID becomes stale.
		Task.detached(priority: .background) {
			try? await Task.sleep(nanoseconds: 1_000_000_000)
			cleanStaleServiceInputDirectories()
		}
		let inputDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent(
				"\(serviceInputDirectoryPrefix)\(getpid())-\(UUID().uuidString)",
				isDirectory: true
			)
		try FileManager.default.createDirectory(
			at: inputDirectory,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700]
		)
		defer { try? FileManager.default.removeItem(at: inputDirectory) }
		monitorServiceParent(getppid(), inputDirectory: inputDirectory)
		try writeServiceFrame(
			ServiceHello(
				inputDirectory: inputDirectory.path
			))
		let decoder = JSONDecoder()
		var activeRequest:
			(
				id: UInt32,
				task: Task<Void, Never>,
				responseControl: ServiceResponseControl,
				credits: ServiceCredits?
			)?
		while let frame = try readServiceFrame() {
			let request = try decoder.decode(ServiceRequest.self, from: frame)
			switch request.command {
			case .some("cancel"):
				if activeRequest?.id == request.id {
					activeRequest?.task.cancel()
					if let credits = activeRequest?.credits {
						await credits.cancel()
					}
				}
			case .some("pull"):
				if activeRequest?.id == request.id, let credits = activeRequest?.credits {
					await credits.pull()
				}
			case nil:
				guard let operation = request.operation else {
					throw UsageError("Missing service operation")
				}
				if let previousRequest = activeRequest {
					await previousRequest.task.value
					activeRequest = nil
				}
				let responseControl = ServiceResponseControl()
				let credits = operation == "ocr-pages" || operation == "document-pages" ? ServiceCredits() : nil
				let task = Task {
					do {
						switch operation {
						case "ocr":
							try await processServiceOcr(
								request: request,
								inputDirectory: inputDirectory,
								responseControl: responseControl
							)
						case "ocr-pages":
							guard let credits else {
								throw MessageError("Missing service page credits")
							}
							try await processServicePages(
								request: request,
								inputDirectory: inputDirectory,
								responseControl: responseControl,
								credits: credits
							)
						case "document":
							try await processServiceDocument(
								request: request,
								inputDirectory: inputDirectory,
								responseControl: responseControl
							)
						case "document-pages":
							guard let credits else {
								throw MessageError("Missing service page credits")
							}
							try await processServiceDocument(
								request: request,
								inputDirectory: inputDirectory,
								responseControl: responseControl,
								credits: credits
							)
						case "searchable-pdf":
							try await processSearchablePDF(
								request: request,
								inputDirectory: inputDirectory,
								responseControl: responseControl
							)
						case "languages":
							try processLanguages(request: request, responseControl: responseControl)
						default:
							throw UsageError("Unsupported service operation: \(operation)")
						}
					} catch {
						terminateService(error)
					}
				}
				activeRequest = (
					id: request.id,
					task: task,
					responseControl: responseControl,
					credits: credits
				)
			case .some(let command):
				throw UsageError("Unsupported service command: \(command)")
			}
		}
		if let activeRequest {
			activeRequest.responseControl.suppress()
			activeRequest.task.cancel()
			if let credits = activeRequest.credits {
				await credits.cancel()
			}
			await activeRequest.task.value
		}
	}
}
