import Foundation

// MARK: - OutputTemplate

/// A parsed template string with `[placeholder]` substitution support.
///
/// Supported placeholders:
///
/// | Placeholder   | Value                                                         |
/// |---------------|---------------------------------------------------------------|
/// | `[name]`      | Input filename without extension                              |
/// | `[ext]`       | Input extension, no dot                                       |
/// | `[page]`      | Page number, 1-indexed                                        |
/// | `[pagecount]` | Total page count                                              |
/// | `[dir]`       | Input directory, no trailing slash. Empty for URL/stdin/current dir. |
///
/// Unknown placeholder names are rejected at parse time with a descriptive error.
///
/// Literal `[` that is not part of a placeholder is passed through unchanged —
/// there is no escape syntax. Template strings that need a literal `[foo]`
/// (where `foo` is not a known placeholder) will produce an error, which
/// is the right behaviour: ambiguous strings should fail loudly.
public struct OutputTemplate: Sendable {
	private let segments: [Segment]

	private enum Segment: Sendable {
		case literal(String)
		case placeholder(Placeholder)
	}

	public enum Placeholder: String, CaseIterable, Sendable {
		case name
		case ext
		case page
		case pagecount
		case dir
	}

	public static let validPlaceholderNames: [String] = Placeholder.allCases.map { "[\($0.rawValue)]" }

	/// Parse `template` into a validated sequence of literals and placeholders.
	///
	/// - Throws: `MessageError` with the full list of valid placeholders if an
	///   unknown `[name]` token is found.
	public init(template: String) throws {
		var segments: [Segment] = []
		var remaining = template[...]

		while !remaining.isEmpty {
			if let bracketStart = remaining.firstIndex(of: "[") {
				// Append anything before the `[`
				let prefix = String(remaining[remaining.startIndex..<bracketStart])
				if !prefix.isEmpty {
					segments.append(.literal(prefix))
				}
				remaining = remaining[remaining.index(after: bracketStart)...]

				// Find the closing `]`
				guard let bracketEnd = remaining.firstIndex(of: "]") else {
					// Unclosed `[` — treat as literal
					segments.append(.literal("[" + remaining))
					remaining = remaining[remaining.endIndex...]
					break
				}

				let token = String(remaining[remaining.startIndex..<bracketEnd])
				remaining = remaining[remaining.index(after: bracketEnd)...]

				if let placeholder = Placeholder(rawValue: token.lowercased()) {
					segments.append(.placeholder(placeholder))
				} else {
					let valid = Self.validPlaceholderNames.joined(separator: ", ")
					throw MessageError(
						"Unknown placeholder '[\(token)]' in output template. Valid placeholders: \(valid)"
					)
				}
			} else {
				segments.append(.literal(String(remaining)))
				break
			}
		}

		self.segments = segments
	}

	// MARK: - Rendering

	struct Context {
		/// The source image loader (for path-based placeholders).
		let sourcePath: String?
		/// Current page number, 1-indexed.
		let page: Int
		/// Total page count.
		let pageCount: Int
	}

	/// Render the template with the given context.
	///
	/// - Returns: The rendered path string.
	func render(context: Context) throws -> String {
		var result = ""
		var dropLeadingSlashFromNextLiteral = false

		for segment in segments {
			switch segment {
			case .literal(let text):
				if dropLeadingSlashFromNextLiteral, text.hasPrefix("/") {
					result += String(text.dropFirst())
				} else {
					result += text
				}
				dropLeadingSlashFromNextLiteral = false

			case .placeholder(let placeholder):
				if dropLeadingSlashFromNextLiteral {
					dropLeadingSlashFromNextLiteral = false
				}
				let value = try resolveValue(for: placeholder, context: context)
				if value.isEmpty {
					dropLeadingSlashFromNextLiteral = true
					continue
				}
				result += value
			}
		}

		return result
	}

	private func resolveValue(for placeholder: Placeholder, context: Context) throws -> String {
		switch placeholder {
		case .name:
			return try resolveName(sourcePath: context.sourcePath)

		case .ext:
			return try resolveExt(sourcePath: context.sourcePath)

		case .page:
			return "\(context.page)"

		case .pagecount:
			return "\(context.pageCount)"

		case .dir:
			return resolveDir(sourcePath: context.sourcePath)
		}
	}

	private func resolveName(sourcePath: String?) throws -> String {
		guard let sourcePath else {
			throw MessageError(
				"Template mode cannot derive [name] without an input filename"
			)
		}
		let url = URL(fileURLWithPath: sourcePath)
		return url.deletingPathExtension().lastPathComponent
	}

	private func resolveExt(sourcePath: String?) throws -> String {
		guard let sourcePath else {
			throw MessageError(
				"Template mode cannot derive [ext] without an input filename"
			)
		}
		let url = URL(fileURLWithPath: sourcePath)
		return url.pathExtension
	}

	private func resolveDir(sourcePath: String?) -> String {
		// URL inputs never reach the URL-detection question here: their
		// `sourcePath` is already a sanitized basename (see `ImageLoader`),
		// which falls out as "" below via the no-parent normalization.
		guard let sourcePath else { return "" }
		let dir = (sourcePath as NSString).deletingLastPathComponent
		// Normalise "/" (root) and "." (current dir with no parent) to ""
		if dir.isEmpty || dir == "/" || dir == "." || dir == sourcePath { return "" }
		return dir
	}

	/// Returns true if the template contains a `[page]` placeholder (1-indexed
	/// page number). Does **not** return true for `[pagecount]` alone.
	///
	/// This is the signal used by analysis commands to switch from consolidated
	/// (one file per source) to per-page (one file per page) output: a `[page]`
	/// reference in the template is an explicit request for per-page splitting,
	/// whereas `[pagecount]` alone is informational and does not vary per page.
	public var referencesPageNumber: Bool {
		segments.contains { segment in
			if case .placeholder(let p) = segment {
				return p == .page
			}
			return false
		}
	}

	/// Returns true if the template needs a source filename.
	///
	/// `[dir]` is intentionally excluded: URL and stdin inputs resolve it to
	/// an empty string, so it does not require a filename-bearing source.
	public var referencesSourceFilename: Bool {
		segments.contains { segment in
			if case .placeholder(let p) = segment {
				return p == .name || p == .ext
			}
			return false
		}
	}
}

// MARK: - Template detection

/// Returns `true` if the string contains at least one `[identifier]` token —
/// any sequence of word characters enclosed in brackets. This covers both known
/// and unknown placeholders so that `parseOutputValue` can route the string to
/// the template parser, which then rejects unknown names with a clear error.
func isTemplateString(_ string: String) -> Bool {
	var remaining = string[...]
	while let bracketStart = remaining.firstIndex(of: "[") {
		remaining = remaining[remaining.index(after: bracketStart)...]
		guard let bracketEnd = remaining.firstIndex(of: "]") else { break }
		let token = String(remaining[remaining.startIndex..<bracketEnd])
		remaining = remaining[remaining.index(after: bracketEnd)...]
		// Any non-empty identifier-like token inside `[...]` qualifies.
		if !token.isEmpty && token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
			return true
		}
	}
	return false
}

/// Returns `true` if the string contains `[` characters but no valid
/// `[identifier]` placeholder was found — indicating a likely typo such as
/// `[[name]]` or `[na me]`.
func hasMalformedPlaceholder(_ string: String) -> Bool {
	string.contains("[") && !isTemplateString(string)
}
