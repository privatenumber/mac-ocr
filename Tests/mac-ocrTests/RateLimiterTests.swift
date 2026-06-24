import Foundation
import Testing

@testable import MacAIKit

/// The cloud backend (Private Cloud Compute) is a shared, quota-limited service,
/// so requests are spaced by a client-side throttle. These pin the spacing math:
/// N requests/minute means request starts are at least 60/N seconds apart, and a
/// rate of 0 disables throttling entirely.
@Suite("RateLimiter")
struct RateLimiterTests {

	@Test func spacesRequestsByConfiguredRate() async throws {
		guard #available(macOS 26.0, *) else { return }
		// 600 rpm -> 0.1s spacing. The first slot is free; 4 more cost ~0.4s.
		let limiter = RateLimiter(requestsPerMinute: 600)
		let clock = ContinuousClock()
		let start = clock.now
		for _ in 0..<5 { await limiter.waitForSlot() }
		let elapsed = start.duration(to: clock.now)
		// Lower bound is firm (4 gaps × 0.1s); allow generous slack for scheduling.
		#expect(elapsed >= .milliseconds(400))
		#expect(elapsed < .milliseconds(2000))
	}

	@Test func zeroRateDisablesThrottling() async throws {
		guard #available(macOS 26.0, *) else { return }
		let limiter = RateLimiter(requestsPerMinute: 0)
		let clock = ContinuousClock()
		let start = clock.now
		for _ in 0..<1000 { await limiter.waitForSlot() }
		#expect(start.duration(to: clock.now) < .milliseconds(100))
	}

	@Test func resolvesCloudBackendFromFlag() {
		guard #available(macOS 26.0, *) else { return }
		#expect(ModelBackend.resolve(cloud: true) == .cloud)
	}
}
