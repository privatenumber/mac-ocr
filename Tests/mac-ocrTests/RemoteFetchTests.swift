import Darwin
import Foundation
import Testing

@testable import MacOcrCore

/// `fetchRemoteData` enforces the URL input size cap and surfaces HTTP/empty
/// failures. Uses a controlled loopback server for streaming and a stub
/// `URLProtocol` for response validation.
@Suite(.serialized) struct RemoteFetchTests {
	private let url = URL(string: "https://example.test/input")!

	private func stubbedConfiguration() -> URLSessionConfiguration {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.protocolClasses = [StubURLProtocol.self]
		return configuration
	}

	@Test func rejectsResponseLargerThanCap() async throws {
		StubURLProtocol.statusCode = 200
		StubURLProtocol.responseData = Data(repeating: 0x41, count: 50)
		StubURLProtocol.contentLength = nil
		do {
			_ = try await fetchRemoteData(from: url, label: "input", maxBytes: 10, configuration: stubbedConfiguration())
			Issue.record("expected an error for an oversized response")
		} catch let error as MessageError {
			#expect(error.message.contains("exceeds"))
		}
	}

	@Test func rejectsResponseLargerThanMisleadingContentLength() async throws {
		StubURLProtocol.statusCode = 200
		StubURLProtocol.responseData = Data(repeating: 0x41, count: 50)
		StubURLProtocol.contentLength = 1
		do {
			_ = try await fetchRemoteData(from: url, label: "input", maxBytes: 10, configuration: stubbedConfiguration())
			Issue.record("expected an error for an oversized response")
		} catch let error as MessageError {
			#expect(error.message.contains("exceeds"))
		}
	}

	@Test func stopsOversizedChunkedResponseBeforeItFinishes() async throws {
		let server = try ChunkedHTTPServer(firstChunk: Data(repeating: 0x41, count: 64 * 1024))
		defer { server.stop() }

		do {
			_ = try await fetchRemoteData(from: server.url, label: "input", maxBytes: 1024)
			Issue.record("expected an error for an oversized response")
		} catch let error as MessageError {
			#expect(error.message.contains("exceeds"))
		}

		#expect(server.waitForClientDisconnection(timeout: 2))
	}

	@Test func stopsDownloadWhenCancelled() async throws {
		let server = try ChunkedHTTPServer()
		defer { server.stop() }
		let task = Task {
			try await fetchRemoteData(from: server.url, label: "input")
		}

		#expect(server.waitForRequest(timeout: 2))
		task.cancel()

		switch await task.result {
		case .success:
			Issue.record("expected cancellation to fail the download")
		case .failure(let error):
			#expect(error is CancellationError)
		}

		#expect(server.waitForClientDisconnection(timeout: 2))
	}

	@Test func acceptsResponseWithinCap() async throws {
		StubURLProtocol.statusCode = 200
		StubURLProtocol.responseData = Data(repeating: 0x41, count: 8)
		StubURLProtocol.contentLength = nil
		let data = try await fetchRemoteData(from: url, label: "input", maxBytes: 1000, configuration: stubbedConfiguration())
		#expect(data.count == 8)
	}

	@Test func rejectsNon200Status() async throws {
		StubURLProtocol.statusCode = 404
		StubURLProtocol.responseData = Data("nope".utf8)
		StubURLProtocol.contentLength = nil
		do {
			_ = try await fetchRemoteData(from: url, label: "input", configuration: stubbedConfiguration())
			Issue.record("expected an error for a non-200 status")
		} catch let error as MessageError {
			#expect(error.message.contains("404"))
		}
	}

	@Test func rejectsEmptyResponse() async throws {
		StubURLProtocol.statusCode = 200
		StubURLProtocol.responseData = Data()
		StubURLProtocol.contentLength = nil
		do {
			_ = try await fetchRemoteData(from: url, label: "input", configuration: stubbedConfiguration())
			Issue.record("expected an error for an empty response")
		} catch let error as MessageError {
			#expect(error.message.contains("No data"))
		}
	}
}

/// Returns a canned HTTP response for any request. Configure via the static
/// properties before each call; the suite is serialized so they don't race.
final class StubURLProtocol: URLProtocol {
	// `nonisolated(unsafe)`: URLProtocol's registration API forces class-level
	// state; safe here because the suite is `.serialized` and each test sets
	// the values before issuing its single request.
	nonisolated(unsafe) static var statusCode = 200
	nonisolated(unsafe) static var responseData = Data()
	nonisolated(unsafe) static var contentLength: Int?

	override class func canInit(with request: URLRequest) -> Bool { true }
	override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
	override func stopLoading() {}

	override func startLoading() {
		let response = HTTPURLResponse(
			url: request.url!,
			statusCode: Self.statusCode,
			httpVersion: "HTTP/1.1",
			headerFields: Self.contentLength.map { ["Content-Length": "\($0)"] }
		)!
		client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
		client?.urlProtocol(self, didLoad: Self.responseData)
		client?.urlProtocolDidFinishLoading(self)
	}
}

/// Sends one chunk above the configured limit, then waits for the client to
/// close the connection before it sends another chunk.
private final class ChunkedHTTPServer: @unchecked Sendable {
	private let listener: Int32
	private let requestReceived = DispatchSemaphore(value: 0)
	private let result = DispatchSemaphore(value: 0)
	private let resultLock = NSLock()
	private var didClientDisconnect = false

	private(set) var url: URL!

	init(firstChunk: Data? = nil) throws {
		listener = socket(AF_INET, SOCK_STREAM, 0)
		guard listener >= 0 else {
			throw POSIXError(.ENFILE)
		}

		var address = sockaddr_in()
		address.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
		address.sin_family = sa_family_t(AF_INET)
		address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

		let didBind = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
			}
		}
		guard didBind == 0, listen(listener, SOMAXCONN) == 0 else {
			close(listener)
			throw POSIXError(.EADDRINUSE)
		}

		var boundAddress = sockaddr_in()
		var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
		let didGetAddress = withUnsafeMutablePointer(to: &boundAddress) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				getsockname(listener, $0, &boundAddressLength)
			}
		}
		guard didGetAddress == 0 else {
			close(listener)
			throw POSIXError(.EINVAL)
		}

		url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: boundAddress.sin_port))/input")!

		DispatchQueue.global().async { [self] in
			let client = accept(listener, nil, nil)
			guard client >= 0 else {
				result.signal()
				return
			}
			defer {
				close(client)
				result.signal()
			}

			var request = [UInt8](repeating: 0, count: 4_096)
			guard recv(client, &request, request.count, 0) > 0 else {
				return
			}
			requestReceived.signal()

			let headers = Data("HTTP/1.1 200 OK\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
			guard send(client, headers) else {
				return
			}
			if let firstChunk {
				let chunk = Data("\(String(firstChunk.count, radix: 16))\r\n".utf8) + firstChunk + Data("\r\n".utf8)
				guard send(client, chunk) else {
					return
				}
			}

			var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
			guard poll(&descriptor, 1, 2_000) > 0 else {
				let _ = send(client, Data("1\r\nB\r\n0\r\n\r\n".utf8))
				return
			}

			var byte: UInt8 = 0
			resultLock.lock()
			didClientDisconnect = recv(client, &byte, 1, 0) == 0
			resultLock.unlock()
		}
	}

	deinit {
		close(listener)
	}

	func stop() {
		close(listener)
	}

	func waitForRequest(timeout: TimeInterval) -> Bool {
		requestReceived.wait(timeout: .now() + timeout) == .success
	}

	func waitForClientDisconnection(timeout: TimeInterval) -> Bool {
		let _ = result.wait(timeout: .now() + timeout)
		resultLock.lock()
		defer { resultLock.unlock() }
		return didClientDisconnect
	}

	private func send(_ client: Int32, _ data: Data) -> Bool {
		data.withUnsafeBytes {
			guard let baseAddress = $0.baseAddress else {
				return false
			}
			return Darwin.send(client, baseAddress, data.count, 0) == data.count
		}
	}
}
