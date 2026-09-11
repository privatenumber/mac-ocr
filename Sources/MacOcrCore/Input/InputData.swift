import Foundation

/// Cap on the response-body data retained for a remote (http/https) input.
/// URLSession and the network stack can buffer additional bytes while a request
/// is in flight. Oversized responses are rejected and cancelled; the resource
/// timeout bounds a server that does not finish the transfer.
let maxRemoteInputBytes = 100 * 1024 * 1024

/// A URLSession configured for input downloads: explicit request and resource
/// timeouts instead of `URLSession.shared`'s default 60s request timeout / no
/// resource cap.
func makeRemoteInputSession(delegate: URLSessionDataDelegate, configuration: URLSessionConfiguration? = nil) -> URLSession {
	let configuration = configuration ?? URLSessionConfiguration.ephemeral
	configuration.timeoutIntervalForRequest = 30
	configuration.timeoutIntervalForResource = 120
	return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
}

/// Download an http(s) input with explicit timeouts and a size cap, replacing
/// `URLSession.shared.data` (which has no size limit and only the default 60s
/// request timeout). Verifies the HTTP status and rejects empty or oversized
/// responses. `maxBytes`/`configuration` are injectable for testing.
func fetchRemoteData(
	from url: URL,
	label: String,
	maxBytes: Int = maxRemoteInputBytes,
	configuration: URLSessionConfiguration? = nil
) async throws -> Data {
	let collector = RemoteDataCollector(label: label, maxBytes: maxBytes)
	let session = makeRemoteInputSession(delegate: collector, configuration: configuration)
	defer { session.invalidateAndCancel() }
	return try await withTaskCancellationHandler {
		try await collector.fetch(from: url, session: session)
	} onCancel: {
		collector.cancel()
	}
}

/// The lock coordinates URLSession delegate callbacks with task cancellation.
private final class RemoteDataCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
	private let label: String
	private let maxBytes: Int
	private let lock = NSLock()
	private var data = Data()
	private var dataTask: URLSessionDataTask?
	private var continuation: CheckedContinuation<Data, Error>?
	private var isCancelled = false

	init(label: String, maxBytes: Int) {
		self.label = label
		self.maxBytes = maxBytes
	}

	func fetch(from url: URL, session: URLSession) async throws -> Data {
		try await withCheckedThrowingContinuation { continuation in
			lock.lock()
			if isCancelled {
				lock.unlock()
				continuation.resume(throwing: CancellationError())
				return
			}
			let dataTask = session.dataTask(with: url)
			self.continuation = continuation
			self.dataTask = dataTask
			lock.unlock()
			dataTask.resume()
		}
	}

	func cancel() {
		lock.lock()
		isCancelled = true
		let dataTask = self.dataTask
		let continuation = self.continuation
		self.dataTask = nil
		self.continuation = nil
		lock.unlock()
		dataTask?.cancel()
		continuation?.resume(throwing: CancellationError())
	}

	func urlSession(
		_ session: URLSession,
		dataTask: URLSessionDataTask,
		didReceive response: URLResponse,
		completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
	) {
		if let http = response as? HTTPURLResponse, http.statusCode != 200 {
			finish(.failure(MessageError("HTTP \(http.statusCode) for \(label)")))
			completionHandler(.cancel)
			return
		}

		if response.expectedContentLength > Int64(maxBytes) {
			finish(.failure(sizeLimitError()))
			completionHandler(.cancel)
			return
		}

		completionHandler(.allow)
	}

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive receivedData: Data) {
		lock.lock()
		guard continuation != nil else {
			lock.unlock()
			return
		}
		let exceedsLimit = receivedData.count > maxBytes - data.count
		if !exceedsLimit {
			data.append(receivedData)
		}
		lock.unlock()

		if exceedsLimit {
			finish(.failure(sizeLimitError()))
			dataTask.cancel()
		}
	}

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		if let error {
			finish(.failure(error))
			return
		}

		lock.lock()
		let data = self.data
		lock.unlock()
		if data.isEmpty {
			finish(.failure(MessageError("No data received from \(label)")))
			return
		}
		finish(.success(data))
	}

	private func sizeLimitError() -> MessageError {
		let limit = ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .binary)
		return MessageError("\(label) exceeds the \(limit) limit for URL input. Download it and pass the local file instead.")
	}

	private func finish(_ result: Result<Data, Error>) {
		lock.lock()
		let continuation = self.continuation
		self.dataTask = nil
		self.continuation = nil
		lock.unlock()
		continuation?.resume(with: result)
	}
}

/// Read all of standard input. Uses the throwing `readToEnd()` where available
/// so an I/O failure (e.g. a broken pipe feeding stdin) surfaces as a catchable
/// Swift error and a clean exit, rather than the uncatchable Objective-C
/// exception `readDataToEndOfFile()` raises.
func readAllStandardInput() throws -> Data {
	if #available(macOS 10.15.4, *) {
		return try FileHandle.standardInput.readToEnd() ?? Data()
	}
	return FileHandle.standardInput.readDataToEndOfFile()
}
