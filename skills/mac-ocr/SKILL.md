---
name: mac-ocr
description: Run the `mac-ocr` macOS CLI (or its Node.js API) to recognize text in images and PDFs, extract structured document content on macOS 26+, or create a searchable PDF from a scanned PDF or an image with an invisible selectable text layer. Use when asked to OCR, extract or read text from an image or PDF, stream text from a large PDF page by page, extract paragraphs/tables/lists from a document, make a scanned PDF searchable/selectable, or convert an image (PNG, JPEG, HEIC, ...) into a searchable PDF - on-device via Apple's Vision framework. Covers the default OCR action (text/JSON/JSONL output, batching, stdin, URLs, languages, regions, encrypted-PDF passwords), the macOS 26 `document`, `searchable-pdf`, and `languages` subcommands, and the Node API (`ocr`, `ocr.pages`, `ocrDocument`, `ocrDocument.pages`, `createSearchablePdf`, `supportedLanguages`). macOS only; not for editing or replacing a PDF's existing text.
---

# mac-ocr

`mac-ocr` recognizes text in images and PDFs, extracts structured documents on macOS 26+, and writes searchable PDFs on macOS via Apple's Vision framework. Three operations:

- **OCR** (the default action) — recognize text in images and PDFs.
- **`document`** — extract structured document content on macOS 26+.
- **`searchable-pdf`** — write a PDF with an invisible, selectable text layer, from a PDF or an image (image → one-page PDF sized from embedded DPI, falling back to 72 DPI).

## OCR (default action — no subcommand)

OCR is the default, so a file argument alone runs recognition. `mac-ocr ocr <file>` also works but isn't required.

```sh
mac-ocr photo.png                       # text → stdout
mac-ocr scan.pdf                         # multi-page PDF, streamed
mac-ocr a.png b.png c.png                # multiple images
cat screenshot.png | mac-ocr             # stdin (auto-detected)
mac-ocr https://example.com/img.png      # URL (simple GET only)
mac-ocr shots/*.png -o '[dir]/[name].txt'  # a .txt next to each image
mac-ocr --format jsonl scans/*.pdf       # streaming JSONL for big jobs
```

### Flags

| Flag | Effect |
|------|--------|
| `-f, --format <text\|json\|jsonl>` | Output format. Default `text`. |
| `-o, --output <path>` | Write to a file instead of stdout: fixed path, `dir/`, or a template with `[name]`/`[ext]`/`[dir]`/`[page]`/`[pagecount]` (e.g. `'[dir]/[name].txt'` writes next to each input). Quote templates — `[…]` is a glob in zsh |
| `--pdf-dpi <auto\|72–600>` | PDF rasterization DPI. `auto` (default) sniffs embedded image resolution, clamped to 144–600; vector-only pages use 144. |
| `--password <pw>` | Password for an encrypted PDF (or set `MAC_OCR_PDF_PASSWORD`) |
| `--fast` | Lower accuracy, faster |
| `-l, --language <code>` | Recognition language (BCP-47, repeatable), e.g. `-l en-US -l ja-JP` |
| `-c, --confidence <0–1>` | Drop observations below threshold |
| `-w, --custom-words <word>` | Custom vocabulary (repeatable) |
| `--custom-words-file <path>` | Vocabulary file, one word per line |
| `--no-language-correction` | Disable language correction |
| `--min-text-height <0–1>` | Minimum text height relative to image |
| `--max-candidates <1–10>` | Alternative text candidates per observation (default 1; a `candidates` array appears on observations only when > 1) |
| `--roi <x,y,w,h>` | Restrict to a normalized region (top-left origin) |

### Output formats

| Format | Streams? | When to use |
|--------|----------|-------------|
| `text` (default) | ✓ | You just want text. Multi-result runs get `==> filename <==` headers. |
| `jsonl` | ✓ | **Prefer for PDFs, batches, and heavy jobs.** One JSON object per line; memory-bounded, incremental. |
| `json` | ✗ | Only when a downstream tool needs one parseable array. Buffers everything — avoid for large inputs. |

### JSON shape

Each result (one per image, or one per PDF page) is:

```jsonc
{
  "source": { "type": "file", "path": "scan.pdf" },
  "page": 1,
  "pageCount": 3,
  "width": 1224,
  "height": 1584,
  "text": "Full recognized text\nwith newlines",
  "observations": [
    {
      "text": "Full recognized text",
      "confidence": 1.0,
      "boundingBox": { "x": 0.05, "y": 0.42, "width": 0.37, "height": 0.06 },
      "requestRevision": 3
    }
  ]
}
```

Bounding boxes are normalized `0–1` with a **top-left origin**. To get pixels: `obs.boundingBox.x * result.width`, `obs.boundingBox.y * result.height`.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success (even if no text found) |
| `1` | Runtime error (missing file, unreadable image, partial batch failure) |
| `64` | Invalid flag value |

## document (macOS 26+)

`document` extracts structured document content: a convenience transcript plus paragraphs, tables, lists, line candidates, and normalized geometry. Use JSON when structure matters:

```sh
mac-ocr document receipt.jpg --format json
mac-ocr document book.pdf --format jsonl
mac-ocr document invoice.png -l en --max-candidates 3
```

- Requires macOS 26+. On older systems it reports an unavailable error; use ordinary OCR if structure is not required.
- Accepts `--format`, `--output`, `--pdf-dpi`, `--roi`, and `--password` like OCR.
- Document languages use identifiers reported by the current macOS runtime, for example `-l en`, `-l zh-TW`, or `-l ar-SA`. `en-US` is not accepted by the current document recognizer.
- Accepts `-w/--custom-words`, `--custom-words-file`, `--no-language-correction`, `--min-text-height`, and `--max-candidates`.
- Does not accept `--fast` or `--confidence` because the document recognizer cannot preserve those ordinary-OCR contracts.
- Do not concatenate paragraphs, tables, and lists to form text. Use root `text`; structural collections are overlapping views of the document.

## searchable-pdf

Writes a PDF that looks identical to the source but with selectable, searchable text. By default writes one `[name].ocr.pdf` per input; pass `--merge` to combine inputs into one PDF.

```sh
mac-ocr searchable-pdf scan.pdf                      # writes scan.ocr.pdf
mac-ocr searchable-pdf photo.jpg                      # image → one-page photo.ocr.pdf
mac-ocr searchable-pdf *.pdf                          # writes <name>.ocr.pdf for each
mac-ocr searchable-pdf scan.pdf -o out/               # out/scan.ocr.pdf
mac-ocr searchable-pdf scan.pdf -o '[name]-ocr.pdf'   # scan-ocr.pdf
mac-ocr searchable-pdf scan.pdf -o -                  # PDF to stdout (refused on a TTY)
mac-ocr searchable-pdf --merge -o lease.pdf page1.jpg page2.jpg
```

- **`-o <dest>`**: path, `[name]` template, directory, or `-` for stdout. A fixed path or `-` takes a single input; multiple inputs need a directory or `[name]` template.
- **`--merge`** combines file/URL inputs into one searchable PDF in exact argument order. It requires `-o <file.pdf>` or `-o -`; directory, template, and stdin inputs are rejected. Merged PDFs are rewritten, so annotations/outlines/metadata are not preserved.
- **PDF inputs** keep their original pages verbatim in non-merge mode (vector content is not re-rasterized); only an invisible text layer is added, and pages that already have selectable text are left untouched. The page is rasterized internally to feed OCR.
- **Fully born-digital PDFs pass through byte-for-byte in non-merge mode** (annotations/links/forms/outlines preserved). When any page needs OCR or `--merge` is used, the rewrite preserves page content but **not** annotations, outlines, or metadata.
- **`--ocr-all-pages`** overrides that skip and OCRs every page — needed for hybrid pages (a scan plus a small digital stamp/page number, which counts as "has text"); existing digital text may then appear twice in copy/search.
- **Image inputs** become one page, sized from embedded DPI metadata when available. Images without usable DPI metadata fall back to 72 DPI (1px = 1pt).
- **`--image-quality <0–1>`** controls the visible image layer for image inputs only. OCR still uses the original full-resolution image; PDF inputs are not recompressed.
- **`--image-page-dpi <36–2400>`** overrides image input page sizing only. OCR still uses the original full-resolution image; PDF inputs are unaffected. `--pdf-dpi` remains PDF-page rasterization for OCR.
- **`--image-downsample-dpi <36–2400>`** caps the visible image layer resolution for image inputs only. OCR and page size are unaffected; PDF inputs are not downsampled.
- **Advanced diagnostics:** `MAC_OCR_DEBUG=1` draws searchable-PDF OCR boxes into file outputs and writes a JSONL sidecar next to each output PDF (`file.pdf` → `file.jsonl`). Use it when diagnosing missing/duplicated text: red accepted line boxes, blue word boxes, orange rejected observations; sidecar records `recognition.passes.partitioned`, `origin`, and `rejection.reason`/`supersededBy`. Rejected with `-o -`; schema is diagnostic, not a public compatibility contract.
- **`--ocr-strategy auto|standard|partitioned`** controls searchable-PDF OCR strategy. `auto` is default and may run recursive partitioned OCR for large pages with small detected text; `standard` forces full-page OCR only; `partitioned` forces partitioned OCR for eligible pages. Partitioning splits each region along its longer axis with overlap, then keeps splitting only while the region is above the calibrated Vision size floor and text remains small or absent. Very large partitioned runs show an interactive warning after the full-page pass. Auto skips partitioning when `--roi` is set; forced `partitioned` mode rejects `--roi`.
- Accepts the same recognition options as OCR (`--fast`, `-l`, `-c`, `--pdf-dpi`, `--roi`, `--password`, custom words, etc.).
- Status is **interactive-only** on stderr: a live `[page/total]` counter + `name → path` line on a terminal; piped runs are silent on success (errors only) — no quiet flag needed. stdout stays clean for `-o -`. The `ocr` command shows the same counter when results aren't streaming to the terminal.

The text layer is word-level: one invisible run per recognized word, positioned from Vision's per-word geometry, so selection rectangles track the printed words. Text is searchable and copyable; width within a word remains approximate.

## languages

List the recognition languages supported on this macOS version (one BCP-47 code per line). They apply to both OCR and `searchable-pdf`.

```sh
mac-ocr languages           # accurate recognizer
mac-ocr languages --fast    # fast recognizer's set
```

## Node.js API

The package also exposes a typed, promise-based API (`import { ocr, ocrDocument, createSearchablePdf, supportedLanguages } from 'mac-ocr'`) backed by the bundled binary. Inputs are **bytes** (Buffer/Uint8Array/ArrayBuffer) — read files or fetch URLs in your own code.

```ts
const { text, observations } = await ocr(bytes)          // single image or single-page PDF
for await (const page of ocr.pages(pdfBytes)) { /* … */ } // stream multi-page PDF
const pages = await Array.fromAsync(ocr.pages(pdfBytes))  // …or collect → OcrResult[]
const document = await ocrDocument(bytes, { languages: ['en'] }) // macOS 26+, single page
for await (const page of ocrDocument.pages(pdfBytes)) { /* … */ }
const pdf = await createSearchablePdf(bytes)                    // → Uint8Array (PDF bytes)
const langs = await supportedLanguages()                  // → string[] (ocr + createSearchablePdf)
```

- `ocr()` and `ocrDocument()` throw for multi-page PDFs — use their respective `.pages()` iterators.
- Main-thread calls run one at a time through the shared native service. Avoid an unbounded `Promise.all()` burst, and keep input bytes unchanged until each call settles.
- Options mirror the CLI: `fast`, `languages`, `confidence`, `customWords`, `languageCorrection` (default true), `minTextHeight`, `maxCandidates`, `regionOfInterest` (`{x,y,width,height}` | `[x,y,width,height]` | `"x,y,w,h"`), `pdfDpi`, `ocrStrategy`, `imageQuality`, `imagePageDpi`, and `imageDownsampleDpi` (searchable PDF only), `password`, `signal` (AbortSignal). `ocrDocument` does not accept `fast` or `confidence`.
- Failures throw `MacOcrError` with `.kind` (`'usage'`, `'runtime'`, `'unavailable'`, …) and `.stderr`.

## Patterns

**Heavy/batch jobs → stream JSONL to disk:**

```sh
mac-ocr --format jsonl large-docs/*.pdf > results.jsonl   # memory-bounded, one line per page
```

**HTTP with auth/POST/cookies** — `mac-ocr` only does simple GET; fetch upstream and pipe:

```sh
curl -H "Authorization: Bearer $TOKEN" https://api.example.com/img | mac-ocr -
```
