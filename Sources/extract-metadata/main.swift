import Foundation
import FoundationModels
import MacAIKit

// extract-metadata — extract structured metadata from OCR'd documents as JSON,
// constrained to a caller-supplied schema, using Apple's on-device model.
//
// The schema is plain JSON describing the fields you want. The model is forced
// (via a runtime GenerationSchema) to emit JSON that conforms to it.
//
// Usage:
//   mac-ocr doc.pdf | extract-metadata --schema schema.json
//   extract-metadata --schema schema.json a.txt b.txt      # "<file>\t<json>" per line
//   producer | extract-metadata --schema schema.json --batch   # NUL-sep docs -> JSONL
//
// Schema format (a JSON object). Either a map of field -> spec:
//   {
//     "vendor":   { "type": "string",  "description": "company that issued it" },
//     "total":    { "type": "number",  "description": "grand total" },
//     "date":     { "type": "string",  "description": "document date" },
//     "paid":     { "type": "boolean", "optional": true },
//     "line_items": { "type": "array", "items": { "type": "string" } }
//   }
// A bare type string ("string") is shorthand. Nested objects use
// { "type": "object", "properties": { … } }. Types: string, integer, number,
// boolean, array, object.

let instructions = """
	You extract structured metadata from a scanned document's text. Fill every field \
	of the provided schema using only information present in the document. Spell words \
	correctly and fix obvious scan errors — for example a digit "0" used inside a word \
	that should be the letter "o", or "1" that should be "l" — but copy numbers, codes, \
	and reference numbers exactly. If a value is not present, use an empty string, or 0 \
	for numbers and false for booleans.
	"""

func fail(_ message: String) -> Never {
	FileHandle.standardError.write(Data(("extract-metadata: " + message + "\n").utf8))
	exit(1)
}

func warn(_ message: String) {
	FileHandle.standardError.write(Data(("extract-metadata: " + message + "\n").utf8))
}

struct SchemaError: Error {
	let message: String
	init(_ message: String) { self.message = message }
}

// Build a runtime DynamicGenerationSchema from a parsed JSON spec node.
@available(macOS 26.0, *)
func buildSchema(_ spec: Any, name: String) throws -> DynamicGenerationSchema {
	if let typeName = spec as? String {
		return try primitive(typeName, name: name)
	}
	guard let dict = spec as? [String: Any] else {
		throw SchemaError("field '\(name)': spec must be a type string or an object")
	}
	let type =
		(dict["type"] as? String)
		?? (dict["properties"] != nil ? "object" : (dict["items"] != nil ? "array" : "string"))

	switch type {
	case "string", "integer", "number", "boolean":
		return try primitive(type, name: name)
	case "array":
		guard let items = dict["items"] else { throw SchemaError("array '\(name)' needs an \"items\" spec") }
		return DynamicGenerationSchema(arrayOf: try buildSchema(items, name: name + "_item"))
	case "object":
		guard let props = dict["properties"] as? [String: Any] else {
			throw SchemaError("object '\(name)' needs a \"properties\" object")
		}
		let properties = try props.sorted { $0.key < $1.key }.map { key, value -> DynamicGenerationSchema.Property in
			let childDict = value as? [String: Any]
			return DynamicGenerationSchema.Property(
				name: key,
				description: childDict?["description"] as? String,
				schema: try buildSchema(value, name: key),
				isOptional: (childDict?["optional"] as? Bool) ?? false
			)
		}
		return DynamicGenerationSchema(name: name, description: dict["description"] as? String, properties: properties)
	default:
		throw SchemaError("field '\(name)': unknown type '\(type)'")
	}
}

@available(macOS 26.0, *)
func primitive(_ type: String, name: String) throws -> DynamicGenerationSchema {
	switch type {
	case "string": return DynamicGenerationSchema(type: String.self)
	case "integer": return DynamicGenerationSchema(type: Int.self)
	case "number": return DynamicGenerationSchema(type: Double.self)
	case "boolean": return DynamicGenerationSchema(type: Bool.self)
	default: throw SchemaError("field '\(name)': unknown type '\(type)'")
	}
}

// Re-encode a parsed JSON object graph deterministically: repair OCR glitches in
// string values (reusing MacAIKit.fixWordOcr), format numbers with Swift's
// shortest round-trip (so 11.89 stays "11.89", not "11.890000000000001"), and
// sort object keys. JSONSerialization is used only as the parser.
func isBool(_ value: Any) -> Bool {
	CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
}

func encodeJSONString(_ raw: String) -> String {
	var out = "\""
	for scalar in raw.unicodeScalars {
		switch scalar {
		case "\"": out += "\\\""
		case "\\": out += "\\\\"
		case "\n": out += "\\n"
		case "\t": out += "\\t"
		case "\r": out += "\\r"
		case let s where s.value < 0x20: out += String(format: "\\u%04x", s.value)
		default: out.unicodeScalars.append(scalar)
		}
	}
	return out + "\""
}

func encodeJSON(_ value: Any) -> String {
	if value is NSNull { return "null" }
	if isBool(value) { return (value as? Bool) == true ? "true" : "false" }
	if let number = value as? NSNumber {
		let d = number.doubleValue
		if d.rounded() == d && abs(d) < 1e15 { return String(number.int64Value) }
		return String(d)  // Swift's shortest round-trippable representation
	}
	if let string = value as? String { return encodeJSONString(fixWordOcr(string)) }
	if let array = value as? [Any] { return "[" + array.map(encodeJSON).joined(separator: ",") + "]" }
	if let dict = value as? [String: Any] {
		let entries = dict.sorted { $0.key < $1.key }
			.map { encodeJSONString($0.key) + ":" + encodeJSON($0.value) }
		return "{" + entries.joined(separator: ",") + "}"
	}
	return "null"
}

@available(macOS 26.0, *)
func extract(from text: String, schema: GenerationSchema, backend: ModelBackend, limiter: RateLimiter) async -> String {
	let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
	guard !trimmed.isEmpty else { return "{}" }

	// Metadata fields can sit anywhere in a document, so send more context than
	// the filename tool does. A full English wrapper avoids the language guardrail.
	// The cloud backend's larger context window comfortably holds this clip.
	let clipped = String(trimmed.prefix(4000))
	let session = makeSession(instructions: instructions, backend: backend)
	let prompt = "Read the following scanned document and extract its metadata.\n\nDocument text:\n\(clipped)"

	do {
		// Schema-constrained generation yields JSON guaranteed to match the schema.
		// No token cap: a cap could truncate the JSON and make it invalid.
		await limiter.waitForSlot()
		let content = try await session.respond(
			to: prompt,
			schema: schema,
			includeSchemaInPrompt: true,
			options: deterministicOptions()
		).content
		let raw = content.jsonString
		if ProcessInfo.processInfo.environment["EXTRACT_RAW"] != nil { return raw }
		guard
			let data = raw.data(using: .utf8),
			let parsed = try? JSONSerialization.jsonObject(with: data)
		else {
			return raw
		}
		return encodeJSON(parsed)
	} catch {
		warn("model request failed: \(error)")
		return "{}"
	}
}

@available(macOS 26.0, *)
func run() async {
	var schemaSource: String?
	var schemaInline: String?
	var batch = false
	var cloud = false
	var paths: [String] = []
	let args = Array(CommandLine.arguments.dropFirst())
	var i = 0
	while i < args.count {
		let arg = args[i]
		switch arg {
		case "--schema":
			i += 1
			guard i < args.count else { fail("--schema needs a file path") }
			schemaSource = args[i]
		case "--schema-json":
			i += 1
			guard i < args.count else { fail("--schema-json needs a JSON string") }
			schemaInline = args[i]
		case "--batch":
			batch = true
		case "--cloud":
			cloud = true
		case "--device":
			cloud = false
		case "-h", "--help":
			print(
				"""
				Usage:
				  extract-metadata --schema <file>           one doc on stdin -> JSON on stdout
				  extract-metadata --schema <file> FILE...   "<file>\\t<json>" per line
				  extract-metadata --schema <file> --batch   NUL-separated docs -> JSONL
				  extract-metadata --schema-json '<json>'    pass the schema inline

				Schema is a JSON object of field -> { "type": …, "description": …, "optional": … }.
				Types: string, integer, number, boolean, array (with "items"), object (with "properties").

				Model backend:
				  --device                 use the on-device model (default)
				  --cloud                  use Apple's Private Cloud Compute model (larger, 32k context)
				  (or set MAC_AI_BACKEND=device|cloud)
				  MAC_AI_CLOUD_RPM=N       throttle cloud requests to N per minute (default 15, 0 = off)
				"""
			)
			exit(0)
		default:
			paths.append(arg)
		}
		i += 1
	}

	// Resolve the schema JSON text.
	let schemaText: String
	if let inline = schemaInline {
		schemaText = inline
	} else if let source = schemaSource {
		guard let text = try? String(contentsOfFile: source, encoding: .utf8) else {
			fail("cannot read schema file: \(source)")
		}
		schemaText = text
	} else {
		fail("a schema is required (use --schema <file> or --schema-json '<json>')")
	}

	guard
		let schemaData = schemaText.data(using: .utf8),
		let topLevel = try? JSONSerialization.jsonObject(with: schemaData)
	else {
		fail("schema is not valid JSON")
	}

	// Accept either a full spec node ({"type":"object",…}) or a bare field map.
	let rootSpec: Any
	if let dict = topLevel as? [String: Any], dict["type"] == nil, dict["properties"] == nil {
		rootSpec = ["type": "object", "properties": dict]
	} else {
		rootSpec = topLevel
	}

	let schema: GenerationSchema
	do {
		let root = try buildSchema(rootSpec, name: "Metadata")
		schema = try GenerationSchema(root: root, dependencies: [])
	} catch let error as SchemaError {
		fail("invalid schema: \(error.message)")
	} catch {
		fail("invalid schema: \(error)")
	}

	let backend = ModelBackend.resolve(cloud: cloud)
	if let reason = modelUnavailableReason(backend) { fail(reason) }
	if let note = cloudQuotaWarning(backend) { warn(note) }
	let limiter = makeRateLimiter(for: backend)

	// Warm the model once so the first document isn't slower.
	let warm = makeSession(instructions: instructions, backend: backend)
	warm.prewarm()

	let concurrency = defaultConcurrency()

	if !paths.isEmpty {
		let lines = await mapConcurrent(paths, concurrency: concurrency) { path in
			guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
				warn("cannot read \(path)")
				return "\(path)\t{}"
			}
			return "\(path)\t\(await extract(from: text, schema: schema, backend: backend, limiter: limiter))"
		}
		for line in lines { print(line) }
		return
	}

	let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""

	if batch {
		let docs = input.components(separatedBy: "\0")
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		guard !docs.isEmpty else { fail("No documents received on stdin.") }
		let results = await mapConcurrent(docs, concurrency: concurrency) { doc in
			await extract(from: doc, schema: schema, backend: backend, limiter: limiter)
		}
		for result in results { print(result) }
		return
	}

	let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
	guard !text.isEmpty else { fail("No OCR text received on stdin.") }
	print(await extract(from: text, schema: schema, backend: backend, limiter: limiter))
}

if #available(macOS 26.0, *) {
	await run()
} else {
	fail("extract-metadata requires macOS 26 (Tahoe) or later with Apple Intelligence.")
}
