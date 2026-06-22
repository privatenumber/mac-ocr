import ArgumentParser
import Foundation
import MacOcrCore

extension Float {
	/// Throw a `ValidationError` if the value is not a finite number in
	/// `[0.0, 1.0]`. Used by every command with a confidence/size/height
	/// flag — centralizes the `isFinite && >= 0 && <= 1` check.
	func requireUnitInterval(name: String) throws {
		guard isFinite, self >= 0.0, self <= 1.0 else {
			throw ValidationError("\(name) must be between 0.0 and 1.0")
		}
	}
}

extension Double {
	/// Throw a `ValidationError` if the value is not a finite number in
	/// `[0.0, 1.0]`.
	func requireUnitInterval(name: String) throws {
		guard isFinite, self >= 0.0, self <= 1.0 else {
			throw ValidationError("\(name) must be between 0.0 and 1.0")
		}
	}
}

/// Shared input-source resolution: map file arguments to `ImageSource`s, and
/// fall back to stdin when no files are given and stdin is piped (not a TTY).
func resolveImageSources(files: [String]) -> [ImageSource] {
	if !files.isEmpty {
		return files.map { ImageSource(argument: $0) }
	}
	if !FileHandle.standardInput.isTerminal {
		return [.stdin]
	}
	return []
}

/// Validate a `--pdf-dpi` argument. Accepts the literal `"auto"` or an
/// integer in `[72, 600]`.
func validatePdfDpi(_ value: String) throws {
	guard value != "auto" else { return }
	guard let parsed = Int(value), parsed >= 72, parsed <= 600 else {
		throw ValidationError("--pdf-dpi must be 'auto' or an integer between 72 and 600")
	}
}

func resolvedPdfDpi(_ value: String) -> Int? {
	value == "auto" ? nil : Int(value)
}

func parseRegionOfInterest(_ value: String) throws -> BoundingBox {
	let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
	guard tokens.count == 4 else {
		throw ValidationError("--roi must be x,y,w,h with four values in 0–1 range")
	}
	let parts = try tokens.map { token -> Double in
		let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let parsed = Double(trimmed) else {
			throw ValidationError("--roi must be x,y,w,h with four values in 0–1 range")
		}
		return parsed
	}
	guard parts.count == 4,
		parts.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
		parts[2] > 0,
		parts[3] > 0
	else {
		throw ValidationError("--roi must be x,y,w,h with four values in 0–1 range")
	}
	if parts[0] + parts[2] > 1 || parts[1] + parts[3] > 1 {
		throw ValidationError(
			"--roi is out of bounds: x+w and y+h must each be ≤ 1 (got x+w=\(parts[0] + parts[2]), y+h=\(parts[1] + parts[3]))"
		)
	}
	return BoundingBox(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
}
