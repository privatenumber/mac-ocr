import ArgumentParser
import Darwin
import Foundation
import MacOcrCore

private let serviceMaxFrameBytes = 64 * 1024 * 1024
private let serviceInputDirectoryPrefix = "mac-ocr-service-"

private struct ServiceHello: Encodable {
	let type = "hello"
	let protocolVersion: Int
	let binaryVersion = macOcrVersion
	let inputDirectory: String
}

private struct ServiceRequest: Decodable {
	let id: UInt32
	let command: String
	let inputName: String
	let arguments: [String]
	let password: String?
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

private struct ServiceResult: Encodable {
	let page: Int
	let pageCount: Int
	let width: Int
	let height: Int
	let text: String
	let observations: [Observation]
}

private struct ServiceResponse: Encodable {
	let id: UInt32
	let type: String
	let result: ServiceResult?
	let error: ServiceError?
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
	FileHandle.standardOutput.write(header)
	FileHandle.standardOutput.write(payload)
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
			try? await Task.sleep(nanoseconds: 1_000_000_000)
		}
		try? FileManager.default.removeItem(at: inputDirectory)
		Darwin.exit(1)
	}
}

private func serviceInputPath(request: ServiceRequest, inputDirectory: URL) throws -> String {
	guard UUID(uuidString: request.inputName) != nil else {
		throw UsageError("Invalid service input name")
	}
	return inputDirectory.appendingPathComponent(request.inputName, isDirectory: false).path
}

private func serviceResult(request: ServiceRequest, inputDirectory: URL) async throws -> ServiceResult {
	guard request.command == "ocr" else {
		throw UsageError("Unsupported service command: \(request.command)")
	}
	let inputPath = try serviceInputPath(request: request, inputDirectory: inputDirectory)
	defer { try? FileManager.default.removeItem(atPath: inputPath) }
	let command = try OCRCommand.parse(request.arguments + [inputPath])
	let options = try command.recognition.buildOCROptions(
		regionOfInterest: try command.common.resolvedROI(),
		maxCandidates: command.maxCandidates
	)
	let loader = try await openSource(
		.file(inputPath),
		pdfDpi: command.common.resolvedPdfDpi,
		pdfPassword: request.password
	)
	guard loader.count == 1 else {
		throw ServiceInputUsageError(
			errorDescription: "Input has multiple pages. Use `ocr.pages()` to read them all."
		)
	}
	let loaded = try loader.load(0)
	let result = try await OCREngine.run(
		session: VisionSession(image: loaded.image, orientation: loaded.orientation),
		options: options
	)
	return ServiceResult(
		page: 1,
		pageCount: 1,
		width: loaded.displayWidth,
		height: loaded.displayHeight,
		text: result.text,
		observations: result.observations
	)
}

private func serviceError(_ error: Error, inputPath: String?) -> ServiceError {
	if let error = error as? ValidationError {
		return ServiceError(
			kind: "usage",
			code: "usage_error",
			message: error.message,
			exitCode: 64,
			stderr: "Error: \(error.message)"
		)
	}
	if let error = error as? UsageError {
		return ServiceError(
			kind: "usage",
			code: "usage_error",
			message: error.message,
			exitCode: 64,
			stderr: "Error: \(error.message)"
		)
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
		let message = MacOcr.message(for: error)
		return ServiceError(
			kind: "usage",
			code: "usage_error",
			message: message,
			exitCode: argumentParserExitCode.rawValue,
			stderr: "Error: \(message)"
		)
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

public enum OCRService {
	public static let protocolVersion = 1

	public static func run() async throws {
		cleanStaleServiceInputDirectories()
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
				protocolVersion: protocolVersion,
				inputDirectory: inputDirectory.path
			))
		let decoder = JSONDecoder()
		while let frame = try readServiceFrame() {
			let request = try decoder.decode(ServiceRequest.self, from: frame)
			let inputPath = try? serviceInputPath(request: request, inputDirectory: inputDirectory)
			do {
				let result = try await serviceResult(
					request: request,
					inputDirectory: inputDirectory
				)
				try writeServiceFrame(
					ServiceResponse(
						id: request.id,
						type: "result",
						result: result,
						error: nil
					)
				)
			} catch {
				try writeServiceFrame(
					ServiceResponse(
						id: request.id,
						type: "error",
						result: nil,
						error: serviceError(error, inputPath: inputPath)
					)
				)
			}
		}
	}
}
