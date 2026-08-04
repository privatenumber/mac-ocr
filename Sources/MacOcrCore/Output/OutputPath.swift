import Foundation

// MARK: - OutputMode

/// How command output should be routed when `--output` / `-o` is set.
///
/// The mode is derived from the flag's presence and value:
///
/// | Flag form                    | Mode       |
/// |------------------------------|------------|
/// | absent                       | `.off`     |
/// | `-o dir/` / `--output dir/` | `.directory(dir)` |
/// | `-o existing-dir`               | `.directory(existing-dir)` |
/// | `-o '[template]'`            | `.template(parsed)` |
/// | `-o path`                    | `.static(path)` |
public enum OutputMode: Sendable {
	/// No output flag — results go to stdout.
	case off
	/// Write into a named directory using the default filename pattern.
	case directory(String)
	/// Write using a custom template string.
	case template(OutputTemplate)
	/// Write to a single fixed path (single-input only).
	case `static`(String)
}

// MARK: - Disambiguation

/// Parse the string value passed to `--output` / `-o` into an `OutputMode`.
///
/// Disambiguation order (documented in the CLI reference):
/// 1. Contains a known `[placeholder]` → template mode
/// 2. Ends with `/` or names an existing directory → directory mode
/// 3. Otherwise                                   → static mode
public func parseOutputValue(_ value: String) throws -> OutputMode {
	if isTemplateString(value) {
		let template = try OutputTemplate(template: value)
		return .template(template)
	}

	// Detect malformed placeholder syntax, e.g. `[[name]]` or `[na me]`.
	// These contain `[` but no valid `[identifier]` was recognised, which
	// almost certainly indicates a typo rather than an intentional literal `[`.
	if hasMalformedPlaceholder(value) {
		let valid = OutputTemplate.validPlaceholderNames.joined(separator: ", ")
		throw MessageError(
			"Malformed template: '\(value)' contains '[' but no valid placeholder was found. " + "Valid placeholders: \(valid). "
				+ "Literal '[' in output paths is not supported in template mode — use a path without brackets for static or directory mode."
		)
	}

	if value.hasSuffix("/") {
		return .directory(value)
	}

	var isDirectory = ObjCBool(false)
	if FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory), isDirectory.boolValue {
		return .directory(value)
	}

	return .static(value)
}

// MARK: - Path resolver

/// Resolve the concrete output file path for a single page result.
///
/// This is the single source of truth for path computation for both the
/// `ocr` analysis output and `searchable-pdf` artifacts.
///
/// **Pure**: no filesystem side effects, so it is safe to call from
/// `validate()` (collision checks) without leaving directories behind on
/// failure. Writers call `ensureParentDirectory(forFile:)` before writing.
///
/// - Parameters:
///   - mode:            The resolved output mode.
///   - sourcePath:      Local input path or URL-derived filename (nil for stdin/buffer).
///   - page:            1-based page number.
///   - pageCount:       Total page count for this source.
///   - outputExtension: File extension including leading dot (e.g. `".png"`, `".txt"`).
/// - Returns: The resolved output path string.
public func resolveOutputPath(
	mode: OutputMode,
	sourcePath: String?,
	page: Int,
	pageCount: Int,
	outputExtension: String
) throws -> String {
	switch mode {
	case .off:
		preconditionFailure("resolveOutputPath called with mode .off — caller should write to stdout")

	case .directory(let directory):
		guard let sourcePath else {
			throw MessageError("--output cannot be used with stdin input")
		}
		// The full basename (extension included) is kept deliberately:
		// `a.png` and `a.jpg` in one batch must not collide on `a.txt`.
		let basename = URL(fileURLWithPath: sourcePath).lastPathComponent
		let pagePart = pageCount > 1 ? ".page-\(page)" : ""
		let filename = basename + pagePart + outputExtension
		return URL(fileURLWithPath: directory).appendingPathComponent(filename).path

	case .template(let template):
		let context = OutputTemplate.Context(
			sourcePath: sourcePath,
			page: page,
			pageCount: pageCount
		)
		return try template.render(context: context)

	case .static(let path):
		return path
	}
}

/// Create the parent directory of `path` if needed — the materializing half
/// of `resolveOutputPath`, called by writers immediately before writing.
public func ensureParentDirectory(forFile path: String) throws {
	let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
	if parent.path != "." && parent.path != "" {
		try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
	}
}
