import Foundation
import FoundationModels
import MacAIKit

// name-file — propose descriptive file names for OCR'd documents using Apple's
// on-device FoundationModels LLM.
//
// Usage:
//   mac-ocr doc.pdf | name-file          one document on stdin -> one name on stdout
//   name-file a.txt b.txt ...            name each text file; prints "<file>\t<name>" per line
//   <producer> | name-file --batch       NUL-separated documents on stdin -> one name per line
//
// Every mode loads the on-device model once, so batch / multi-file runs pay the
// one-time model warmup a single time instead of per document.

// Rather than asking for a slug directly (greedy decoding just concatenates the
// most prominent text — often a letterhead or processor at the top), we have the
// model fill three labeled fields. Forcing a selection per field generalizes
// across document types (receipts, letters, invoices, legal filings, …) and the
// exclusion keeps intermediaries (clerks, notaries, carriers) out of the name.
let instructions = """
You extract three facts from a scanned document's text and reply in exactly this \
format, one per line, nothing else:

party: <the main person or company the document is ABOUT — for example the \
buyer, borrower, customer, sender, account holder, or the business that issued a \
receipt or invoice. NEVER use someone who merely recorded, filed, processed, \
witnessed, notarized, printed, or delivered it, such as a county clerk, \
recorder, registrar, notary, or filing agent. Ignore "return to" and mailing \
addresses. If several parties appear, choose the primary or first-named one — \
for instance a party labeled "primary name", or the buyer or borrower.>
type: <the kind of document — for example receipt, invoice, letter, statement, \
contract, mortgage, deed, report, form>
ref: <the main reference, invoice, order, account, or instrument number, or \
leave this empty if there is none — never invent a number or pad with zeros>

Rules:
- Use only information present in the document.
- Spell words correctly and fix obvious scan errors — for example a digit "0" \
  used inside a word that should be the letter "o", or "1" that should be "l".
- Copy any reference number exactly, digit for digit; do not alter numbers.
- Keep each field short — a few words at most.
"""

func fail(_ message: String) -> Never {
	FileHandle.standardError.write(Data(("name-file: " + message + "\n").utf8))
	exit(1)
}

func warn(_ message: String) {
	FileHandle.standardError.write(Data(("name-file: " + message + "\n").utf8))
}

// fixWordOcr, cleanRef, slugify, mapConcurrent, model-availability and
// concurrency defaults are shared via MacAIKit.

@available(macOS 26.0, *)
func suggestName(for text: String) async -> String? {
	let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
	guard !trimmed.isEmpty else { return nil }

	// Cap the context: the identifying content sits near the top, and a short
	// prompt keeps each request cheap. A fresh session per document avoids one
	// document's text biasing the next.
	// 1000 chars reliably covers where the primary party sits (e.g. a "Borrower"
	// clause two-thirds down page 1); shorter clips run ~10% faster but start
	// missing it. Decode of the ~30-token answer dominates latency, so the
	// token cap is a safety ceiling, not a speed lever.
	let clipped = String(trimmed.prefix(1000))
	let session = LanguageModelSession(instructions: instructions)

	// Greedy is deterministic (same input → same name on reruns). A short
	// English wrapper keeps the request in English — passing raw OCR text as the
	// whole prompt can trip the model's language guardrail.
	let options = deterministicOptions(maximumResponseTokens: 48)

	// A full English sentence around the text keeps the request classified as
	// English; short, number-heavy documents otherwise trip the model's
	// language guardrail (unsupportedLanguageOrLocale).
	let prompt = "Read the following scanned document and extract the requested fields.\n\nDocument text:\n\(clipped)"

	let reply: String
	do {
		reply = try await session.respond(to: prompt, options: options).content
	} catch {
		warn("model request failed: \(error)")
		return nil
	}
	if ProcessInfo.processInfo.environment["NAME_FILE_DEBUG"] != nil {
		warn("raw reply:\n\(reply)")
	}

	// Parse the "party:/type:/ref:" lines. The model sometimes emits a second
	// answer block; keep only the first occurrence of each key and stop once a
	// key repeats (the start of another block).
	var fields: [String: String] = [:]
	for line in reply.split(separator: "\n") {
		guard let colon = line.firstIndex(of: ":") else { continue }
		let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
		guard ["party", "type", "ref"].contains(key) else { continue }
		if fields[key] != nil { break }
		let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
		if !value.isEmpty { fields[key] = value }
	}

	// fixWordOcr only swaps a 0/1 sitting between two letters, so it repairs
	// words (l0an → loan) without ever touching a reference number's digits.
	let parts = [
		fixWordOcr(fields["party"] ?? ""),
		fixWordOcr(fields["type"] ?? ""),
		fixWordOcr(cleanRef(fields["ref"] ?? "")),
	].filter { !$0.isEmpty }

	let assembled = parts.isEmpty ? reply : parts.joined(separator: "-")
	return slugify(assembled)
}

@available(macOS 26.0, *)
func run() async {
	if let reason = systemModelUnavailableReason() { fail(reason) }

	var batch = false
	var paths: [String] = []
	for arg in CommandLine.arguments.dropFirst() {
		switch arg {
		case "--batch":
			batch = true
		case "-h", "--help":
			print("""
			Usage:
			  name-file                one document on stdin -> one name on stdout
			  name-file FILE...        name each text file; prints "<file>\\t<name>" per line
			  name-file --batch        NUL-separated documents on stdin -> one name per line
			""")
			exit(0)
		default:
			paths.append(arg)
		}
	}

	// Pay the model warmup once up front so the first document isn't slower.
	let warm = LanguageModelSession(instructions: instructions)
	warm.prewarm()

	let concurrency = defaultConcurrency()

	// Multi-file mode: each path is a file of OCR text. Emit "<file>\t<name>"
	// so the mapping is scriptable (e.g. for renaming).
	if !paths.isEmpty {
		let lines = await mapConcurrent(paths, concurrency: concurrency) { path in
			guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
				warn("cannot read \(path)")
				return "\(path)\tuntitled-document"
			}
			return "\(path)\t\(await suggestName(for: text) ?? "untitled-document")"
		}
		for line in lines { print(line) }
		return
	}

	let input = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""

	// Batch mode: documents on stdin separated by NUL bytes, one name per line.
	if batch {
		let docs = input.components(separatedBy: "\0")
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.filter { !$0.isEmpty }
		guard !docs.isEmpty else { fail("No documents received on stdin.") }
		let names = await mapConcurrent(docs, concurrency: concurrency) { doc in
			await suggestName(for: doc) ?? "untitled-document"
		}
		for name in names { print(name) }
		return
	}

	// Single-document mode (default).
	let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
	guard !text.isEmpty else { fail("No OCR text received on stdin.") }
	guard let name = await suggestName(for: text) else {
		fail("could not generate a file name.")
	}
	print(name)
}

if #available(macOS 26.0, *) {
	await run()
} else {
	fail("name-file requires macOS 26 (Tahoe) or later with Apple Intelligence.")
}
