import Foundation
import FoundationModels

// Shared building blocks for the on-device AI CLIs (name-file, extract-metadata).
// Keeping these in one library means both tools share the same model-availability
// handling, OCR repair, and concurrency strategy.

/// Which model backend a tool should use. The on-device model is small, fast,
/// and fully local; Private Cloud Compute is a much larger server model with a
/// far bigger context window (~32k vs ~4-8k) that still runs on Apple's
/// privacy-preserving infrastructure. Both are reached through the same
/// FoundationModels API, so picking one is a single switch at session creation.
@available(macOS 26.0, *)
public enum ModelBackend: String, Sendable {
	case device
	case cloud

	/// Resolve the backend from an explicit flag, falling back to the
	/// MAC_AI_BACKEND env var ("device" | "cloud"), then to on-device.
	public static func resolve(cloud: Bool) -> ModelBackend {
		if cloud { return .cloud }
		if let raw = ProcessInfo.processInfo.environment["MAC_AI_BACKEND"]?.lowercased(),
			let backend = ModelBackend(rawValue: raw)
		{
			return backend
		}
		return .device
	}

	public var displayName: String {
		switch self {
		case .device: return "on-device model"
		case .cloud: return "Private Cloud Compute model"
		}
	}
}

/// nil when the selected backend is ready; otherwise a user-facing reason.
@available(macOS 26.0, *)
public func modelUnavailableReason(_ backend: ModelBackend) -> String? {
	switch backend {
	case .device:
		return systemModelUnavailableReason()
	case .cloud:
		// The Private Cloud Compute model and the model: session initializer
		// landed in macOS 27; on 26 there is no cloud path to offer.
		guard #available(macOS 27.0, *) else {
			return "Private Cloud Compute requires macOS 27 (Tahoe) or later."
		}
		let model = PrivateCloudComputeLanguageModel()
		// PrivateCloudComputeLanguageModel exposes a simple availability flag;
		// it can be unavailable when offline, signed out of an Apple Account,
		// or when the app/device is not eligible for the free PCC tier.
		guard model.isAvailable else {
			return "Apple's Private Cloud Compute model is unavailable. Check your network and Apple Account, "
				+ "and that this device/app is eligible for Private Cloud Compute."
		}
		// PCC enforces a per-Apple-Account daily quota; once reached, every
		// request throws, so fail fast with an actionable message instead.
		if model.quotaUsage.isLimitReached {
			return "Private Cloud Compute daily limit reached for this Apple Account. "
				+ "Try again later, run with --device, or raise the limit via iCloud+."
		}
		return nil
	}
}

/// A non-fatal note for the cloud backend (e.g. nearing the daily quota), or nil.
/// Tools can print this as a warning without aborting the run.
@available(macOS 26.0, *)
public func cloudQuotaWarning(_ backend: ModelBackend) -> String? {
	guard backend == .cloud, #available(macOS 27.0, *) else { return nil }
	if case .belowLimit(let info) = PrivateCloudComputeLanguageModel().quotaUsage.status,
		info.isApproachingLimit
	{
		return "Approaching the Private Cloud Compute daily limit for this Apple Account."
	}
	return nil
}

/// Create a session bound to the chosen backend. The on-device path uses
/// `SystemLanguageModel.default` implicitly; the cloud path routes the same
/// request to Private Cloud Compute.
@available(macOS 26.0, *)
public func makeSession(instructions: String, backend: ModelBackend) -> LanguageModelSession {
	switch backend {
	case .device:
		return LanguageModelSession(instructions: instructions)
	case .cloud:
		if #available(macOS 27.0, *) {
			return LanguageModelSession(model: PrivateCloudComputeLanguageModel(), instructions: instructions)
		}
		// Unreachable in practice: callers gate on modelUnavailableReason first,
		// which rejects cloud on macOS 26. Fall back to on-device defensively.
		return LanguageModelSession(instructions: instructions)
	}
}

/// Client-side throttle that spaces out requests to at most N per minute.
/// The on-device model runs locally and needs no throttling; Private Cloud
/// Compute is a shared service with a per-account daily quota, and bursts of
/// concurrent requests (this CLI maps with bounded concurrency) can be
/// throttled server-side. Spacing request *starts* keeps batch runs polite.
/// An interval of 0 disables throttling entirely.
@available(macOS 26.0, *)
public actor RateLimiter {
	private let interval: Duration
	private var nextAllowed: ContinuousClock.Instant?
	private let clock = ContinuousClock()

	public init(requestsPerMinute: Int) {
		interval = requestsPerMinute > 0 ? .seconds(60.0 / Double(requestsPerMinute)) : .zero
	}

	/// Suspend until this caller's slot is due, then reserve the next slot.
	/// Concurrent callers are serialized by the actor and spaced `interval`
	/// apart, so order of arrival is preserved without bursting.
	public func waitForSlot() async {
		guard interval > .zero else { return }
		let now = clock.now
		let scheduled = nextAllowed.map { max($0, now) } ?? now
		nextAllowed = scheduled.advanced(by: interval)
		if scheduled > now {
			try? await Task.sleep(until: scheduled, clock: clock)
		}
	}
}

/// Build the throttle for a backend. The cloud rate (requests/minute) is read
/// from MAC_AI_CLOUD_RPM (default 15); 0 disables it. On-device is unthrottled.
@available(macOS 26.0, *)
public func makeRateLimiter(for backend: ModelBackend) -> RateLimiter {
	switch backend {
	case .device:
		return RateLimiter(requestsPerMinute: 0)
	case .cloud:
		let rpm = Int(ProcessInfo.processInfo.environment["MAC_AI_CLOUD_RPM"] ?? "") ?? 15
		return RateLimiter(requestsPerMinute: rpm)
	}
}

/// nil when the on-device model is ready; otherwise a user-facing reason.
@available(macOS 26.0, *)
public func systemModelUnavailableReason() -> String? {
	switch SystemLanguageModel.default.availability {
	case .available:
		return nil
	case .unavailable(let reason):
		switch reason {
		case .deviceNotEligible:
			return "Apple Intelligence is not supported on this device."
		case .appleIntelligenceNotEnabled:
			return "Apple Intelligence is not enabled. Turn it on in System Settings."
		case .modelNotReady:
			return "The on-device model is downloading or not ready yet. Try again shortly."
		@unknown default:
			return "The on-device language model is unavailable."
		}
	}
}

/// Reasoning effort / sampling shared by the tools: greedy is deterministic, so
/// the same input always yields the same output across reruns.
@available(macOS 26.0, *)
public func deterministicOptions(maximumResponseTokens: Int? = nil) -> GenerationOptions {
	GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumResponseTokens)
}

/// Default request concurrency, overridable with NAME_FILE_CONCURRENCY. The model
/// overlaps two requests (~15% faster per item); beyond two the compute serializes.
public func defaultConcurrency() -> Int {
	Int(ProcessInfo.processInfo.environment["NAME_FILE_CONCURRENCY"] ?? "2") ?? 2
}

/// Run `op` over items with bounded concurrency, preserving input order.
@available(macOS 26.0, *)
public func mapConcurrent<T: Sendable>(
	_ items: [String],
	concurrency: Int,
	_ op: @Sendable @escaping (String) async -> T
) async -> [T] {
	var results = [T?](repeating: nil, count: items.count)
	await withTaskGroup(of: (Int, T).self) { group in
		var next = 0
		for i in 0..<min(max(1, concurrency), items.count) {
			let item = items[i]
			group.addTask { (i, await op(item)) }
			next = i + 1
		}
		while let (idx, value) = await group.next() {
			results[idx] = value
			if next < items.count {
				let i = next
				let item = items[i]
				group.addTask { (i, await op(item)) }
				next += 1
			}
		}
	}
	return results.compactMap { $0 }
}

/// Fix common OCR digit-for-letter confusions inside words (0→O/o, 1→I/i), but
/// only when the digit sits between two letters — so reference codes and numbers
/// are left untouched (e.g. l0an → loan, L1GHTHOUSE → LIGHTHOUSE, while
/// 1234567890 and INV-0456 are unchanged). The replacement matches the case of
/// the preceding letter so casing is preserved.
public func fixWordOcr(_ text: String) -> String {
	let chars = Array(text)
	guard chars.count >= 3 else { return text }
	var out = chars
	for i in 1..<(chars.count - 1) where chars[i] == "0" || chars[i] == "1" {
		guard chars[i - 1].isLetter && chars[i + 1].isLetter else { continue }
		let upper = chars[i - 1].isUppercase
		out[i] = chars[i] == "0" ? (upper ? "O" : "o") : (upper ? "I" : "i")
	}
	return String(out)
}

/// Reject hallucinated reference numbers: an empty result drops the field.
public func cleanRef(_ text: String) -> String {
	if text.count > 24 { return "" }
	let digits = text.filter(\.isNumber)
	if !digits.isEmpty && Set(digits).count == 1 { return "" }  // all-same digit (e.g. 0000…)
	return text
}

/// Sanitize a string into a filesystem-safe kebab-case slug.
public func slugify(_ raw: String) -> String {
	let lowered = raw.lowercased()
	let mapped = lowered.map { ch -> Character in (ch.isLetter || ch.isNumber) ? ch : "-" }
	var slug = String(mapped)
	while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
	slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
	if slug.count > 60 { slug = String(slug.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
	return slug.isEmpty ? "untitled-document" : slug
}
