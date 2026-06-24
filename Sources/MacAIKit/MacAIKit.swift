import Foundation
import FoundationModels

// Shared building blocks for the on-device AI CLIs (name-file, extract-metadata).
// Keeping these in one library means both tools share the same model-availability
// handling, OCR repair, and concurrency strategy.

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
				let i = next, item = items[i]
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
