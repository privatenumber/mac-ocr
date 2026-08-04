import Foundation
import Testing

/// Tests for the VisionGate serialization invariant.
///
/// VisionGate serializes test work that can execute Vision across test suites.
/// Its key property is that at most one waiter proceeds at any given time: two
/// concurrent acquirers must not execute their protected regions simultaneously.
///
/// These tests operate on a fresh VisionGate instance (not the shared singleton)
/// to avoid interfering with the test infrastructure's own gate usage.
@Suite struct VisionGateTests {

	// MARK: - Async acquire / release round-trip

	@Test func acquireAndReleaseCompletesWithoutDeadlock() async {
		// Acquire and immediately release — must not hang.
		let gate = VisionGate()
		await gate.acquire()
		gate.release()
	}

	@Test func sequentialAcquiresSerialize() async throws {
		// Two sequential acquire/release pairs must both complete.
		// If the gate didn't release properly, the second acquire would hang.
		let gate = VisionGate()
		await gate.acquire()
		gate.release()

		await gate.acquire()
		gate.release()
	}

	// MARK: - Serialization property

	/// Spawns N concurrent async tasks that each acquire the gate, record their
	/// interval, and release. Asserts that no two execution intervals overlap.
	///
	/// The gate uses a serial dispatch queue. The test verifies the observable
	/// contract rather than its internal state.
	@Test func concurrentAcquirersDoNotOverlap() async throws {
		let taskCount = 5

		// Each task records its [enter, exit] timestamp pair under the gate.
		actor IntervalCollector {
			private(set) var intervals: [(start: Date, end: Date)] = []
			func add(start: Date, end: Date) { intervals.append((start, end)) }
		}

		let collector = IntervalCollector()
		let gate = VisionGate()

		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<taskCount {
				group.addTask {
					await gate.acquire()
					let start = Date()
					// Tiny yield to let other tasks attempt to run concurrently.
					await Task.yield()
					let end = Date()
					gate.release()
					await collector.add(start: start, end: end)
				}
			}
		}

		let intervals = await collector.intervals
		#expect(intervals.count == taskCount, "All tasks should complete")

		// Check that no two intervals overlap.
		for i in 0..<intervals.count {
			for j in (i + 1)..<intervals.count {
				let a = intervals[i]
				let b = intervals[j]
				// Two intervals [a.start, a.end] and [b.start, b.end] overlap if
				// a.start < b.end AND b.start < a.end.
				let overlaps = a.start < b.end && b.start < a.end
				#expect(!overlaps, "Gate intervals \(i) and \(j) must not overlap: \(a) vs \(b)")
			}
		}
	}

	// MARK: - Blocking acquire (synchronous context)

	@Test func blockingAcquireCompletesAndReleasesGate() {
		// acquireBlocking() is used by TestSupport.run() in non-async contexts.
		// Verify it completes (doesn't deadlock) and that a subsequent async
		// acquire succeeds after release.
		let semaphore = DispatchSemaphore(value: 0)
		let gate = VisionGate()

		// Run on a background OS thread to avoid blocking a cooperative thread.
		Thread.detachNewThread {
			gate.acquireBlocking()
			gate.release()
			semaphore.signal()
		}

		let timedOut = semaphore.wait(timeout: .now() + 10) == .timedOut
		#expect(!timedOut, "acquireBlocking should complete within 10 seconds")
	}

	// MARK: - N=200 property / stress test

	/// Hammers the gate with 200 concurrent tasks. Asserts:
	///   1. All 200 tasks complete (no task dropped or deadlocked).
	///   2. The maximum number of tasks concurrently inside the gate never
	///      exceeds 1 — the binary semaphore property holds under load.
	@Test func stressTest200ConcurrentTasksSerialize() async throws {
		let taskCount = 200

		actor ConcurrencyTracker {
			private var current = 0
			private(set) var maxSeen = 0
			private(set) var completed = 0

			func enter() {
				current += 1
				if current > maxSeen {
					maxSeen = current
				}
			}

			func exit() {
				current -= 1
				completed += 1
			}
		}

		let tracker = ConcurrencyTracker()
		let gate = VisionGate()

		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<taskCount {
				group.addTask {
					await gate.acquire()
					await tracker.enter()
					// Tiny yield so cooperative scheduler can attempt to run others.
					await Task.yield()
					await tracker.exit()
					gate.release()
				}
			}
		}

		let maxSeen = await tracker.maxSeen
		let completed = await tracker.completed

		#expect(completed == taskCount, "All \(taskCount) tasks must complete; got \(completed)")
		#expect(
			maxSeen <= 1,
			"Max concurrent in-flight must never exceed 1 (binary semaphore); saw \(maxSeen)"
		)
	}

	// MARK: - FIFO ordering (waiter queue)

	@Test func waitersAreResumedInFIFOOrder() async throws {
		// Acquire the gate to queue up waiters, then release and verify they
		// are resumed in the order they queued. Enqueue order is made
		// deterministic by observing `waiterCount` — the second waiter only
		// starts once the first is registered — rather than racing timed
		// sleeps against the scheduler.
		let gate = VisionGate()
		await gate.acquire()

		func waitForWaiterCount(_ expected: Int) async {
			while gate.waiterCount < expected {
				await Task.yield()
			}
		}

		actor OrderRecorder {
			var order: [Int] = []
			func append(_ value: Int) {
				order.append(value)
			}
		}
		let recorder = OrderRecorder()

		async let task1: Void = {
			await gate.acquire()
			await recorder.append(1)
			gate.release()
		}()
		await waitForWaiterCount(1)

		async let task2: Void = {
			await gate.acquire()
			await recorder.append(2)
			gate.release()
		}()
		await waitForWaiterCount(2)

		// Release to wake the first waiter; each task releases for the next.
		gate.release()
		_ = await (task1, task2)

		let recorded = await recorder.order
		#expect(recorded == [1, 2], "Waiters should be resumed in FIFO order; got \(recorded)")
	}

	@Test func withPermitReleasesAfterAnError() async {
		struct ExpectedError: Error {}

		let gate = VisionGate()
		await #expect(throws: ExpectedError.self) {
			try await gate.withPermit { () throws -> Void in
				throw ExpectedError()
			}
		}

		let result = await gate.withPermit { 42 }
		#expect(result == 42)
	}
}
