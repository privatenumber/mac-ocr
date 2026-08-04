import Foundation

/// Global binary semaphore that serializes test work which can execute Vision
/// across test suites and across the subprocess / in-process boundary.
///
/// Swift Testing runs different top-level @Suite types concurrently. Vision's
/// in-process runtime serializes its own calls, but subprocesses do not share
/// that runtime. High concurrent Vision load can exhaust GCD's worker pool and
/// stall rather than report an error.
///
/// All test code that touches Vision must flow through this gate:
///   - Subprocess invocations go through TestSupport.run().
///   - Direct calls use withPermit(_:) or a suite lifecycle guard.
///
/// Using a continuation queue rather than NSLock makes the gate safe to
/// acquire from async test functions without blocking cooperative threads.
final class VisionGate: @unchecked Sendable {
	private enum Waiter {
		case continuation(CheckedContinuation<Void, Never>)
		case semaphore(DispatchSemaphore)
	}

	static let shared = VisionGate()

	/// Serial queue used as a lightweight mutex for state mutations.
	private let queue = DispatchQueue(label: "com.privatenumber.mac-ocr.tests.VisionGate")
	private var available = true
	private var waiters: [Waiter] = []

	init() {}

	/// Async acquire — suspends the caller until the gate is free. Safe to call
	/// from async test functions; does not block any cooperative thread.
	func acquire() async {
		await withCheckedContinuation { continuation in
			queue.sync {
				if self.available {
					self.available = false
					continuation.resume()
				} else {
					self.waiters.append(.continuation(continuation))
				}
			}
		}
	}

	@discardableResult
	func withPermit<Result>(_ operation: () async throws -> Result) async rethrows -> Result {
		await acquire()
		defer { release() }
		return try await operation()
	}

	/// Test-only introspection: how many acquirers are currently queued.
	/// Lets ordering tests enqueue waiters deterministically (poll until the
	/// previous waiter is registered) instead of racing timed sleeps.
	var waiterCount: Int {
		queue.sync { waiters.count }
	}

	/// Release — wakes the next waiter if any. May be called from any context.
	func release() {
		queue.async {
			if self.waiters.isEmpty {
				self.available = true
			} else {
				switch self.waiters.removeFirst() {
				case .continuation(let continuation):
					continuation.resume()
				case .semaphore(let semaphore):
					semaphore.signal()
				}
			}
		}
	}

	/// Blocking acquire for synchronous (non-async) test contexts. Only call this
	/// from OS threads — never from async / cooperative contexts.
	func acquireBlocking() {
		let semaphore = DispatchSemaphore(value: 0)
		let isQueued = queue.sync {
			if available {
				available = false
				return false
			}

			waiters.append(.semaphore(semaphore))
			return true
		}

		if isQueued {
			semaphore.wait()
		}
	}
}
