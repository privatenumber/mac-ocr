# CLI reference

`mac-ocr` has one default action (OCR) and two subcommands (`searchable-pdf` and `languages`).

```
mac-ocr <inputs...> [ocr options]          # recognize text (default)
mac-ocr ocr <inputs...> [ocr options]      # explicit form (optional)
mac-ocr searchable-pdf <inputs...> [-o <dest>] [ocr options]
```

Inputs are image or PDF paths, `-` for stdin, or `http(s)://` URLs (simple GET — for auth/POST/cookies, fetch upstream and pipe the bytes in; downloads are capped at 100 MiB with a 30 s request / 120 s total timeout). Images can be any format macOS decodes — PNG, JPEG, TIFF, HEIC, GIF, BMP, … Multiple inputs are processed in order. PDFs are detected by content (`%PDF-` magic bytes), not extension, and EXIF orientation is honored — reported `width`/`height` and bounding boxes are in display orientation.

## OCR (default action)

OCR runs when no subcommand is given, so `mac-ocr photo.png` recognizes text. Piped stdin is recognized automatically (`cat photo.png | mac-ocr`). With no input on an interactive terminal, help is shown.

```sh
mac-ocr receipt.jpg
mac-ocr scan.pdf --format jsonl
mac-ocr a.png b.png c.png
cat shot.png | mac-ocr
mac-ocr https://example.com/sign.png
```

### Options

| Flag | Default | Effect |
|------|---------|--------|
| `-f, --format <text\|json\|jsonl>` | `text` | Output format. `text` and `jsonl` stream; `json` buffers a single array. |
| `-o, --output <path>` | stdout | Output destination. Existing dir or `dir/` → directory mode; `[name]`/`[page]`/`[ext]`/`[pagecount]`/`[dir]` → template mode; otherwise a fixed file (single input only). |
| `--pdf-dpi <auto\|72–600>` | `auto` | PDF rasterization DPI. `auto` derives from the page's largest embedded image, clamped to 144–600 (vector-only pages use 144); renders are capped at 200 MP. |
| `--roi <x,y,w,h>` | full | Region of interest in normalized, top-left-origin coordinates (each in `0–1`; `x+w ≤ 1`, `y+h ≤ 1`). Detection re-normalizes to the region, so this also rescues text too small relative to the full page (see below). |
| `--fast` | off | Character-by-character recognition instead of the default neural net — faster, but lower accuracy. See [Recognition levels](#recognition-levels). |
| `--password <password>` | — | Password for an encrypted PDF. Prefer the `MAC_OCR_PDF_PASSWORD` env var to keep it out of the process list / shell history. |
| `-l, --language <code>` | auto | Recognition language (BCP-47, repeatable), e.g. `-l en-US -l ja-JP`. Validated against `mac-ocr languages` (case-insensitive) — an unsupported code fails with exit 64 instead of silently recognizing nothing. |
| `-c, --confidence <0–1>` | `0` | Drop observations below this confidence. |
| `-w, --custom-words <word>` | — | Custom vocabulary word (repeatable). |
| `--custom-words-file <path>` | — | Custom vocabulary file (one word per line). |
| `--no-language-correction` | off | Disable language correction. |
| `--min-text-height <0–1>` | — | Ignore text shorter than this fraction of image height. |
| `--max-candidates <1–10>` | `1` | Number of alternative text candidates per observation. The `candidates` field appears in the output only when this is > 1. |

> [!TIP]
> Vision's text *detector* can miss text that is very small **relative to the whole image** (roughly under 1% of the image height — e.g. a small receipt scanned in the middle of a large, mostly empty page). Raising `--pdf-dpi` doesn't help, because the ratio stays the same. Restrict analysis to the text's region with `--roi` instead — detection re-normalizes to the region — or crop the input.

### Recognition levels

`--fast` switches Vision's recognition level from `.accurate` (the default) to `.fast`. These are **two different recognition algorithms, not one algorithm with a speed dial**:

- **Accurate** (default) uses a neural network that finds text as whole strings and lines, then reads it as words and sentences — "similar to how humans read text." Because it reasons over whole words, it can interpolate over ambiguous or degraded characters (the same way a proofreader's eye skips over typos).
- **Fast** is a traditional OCR approach: it locates individual characters and recognizes them one at a time with a small model.

The real trade-offs:

| | Accurate (default) | Fast |
|---|---|---|
| Approach | Neural net, word/line level | Character by character |
| Speed | Slower; built for asynchronous/batch use | Optimized for real-time (camera frame rate) |
| Memory | Higher (runs a large neural net) | Lower (no large net) |
| Rotated / skewed text | Broad support | Weak |
| Stylized or decorative fonts | Broad support | Weak |
| Natural-language prose | Best | Weaker |
| Languages | Full set | Often a smaller set |

The last row is easy to miss: **`--fast` and accurate can support different languages.** Vision reports the sets separately, so `mac-ocr languages --fast` may list fewer codes than `mac-ocr languages`.

**When to use which.** Apple designed `.fast` for *live* capture — keeping up with a camera's frame rate while scanning short, structured strings (serial numbers, codes, phone numbers), usually with `--no-language-correction`. For post-processing files and images — which is everything `mac-ocr` does — Apple's guidance is to favor the accurate path "because you can actually use the better accuracy and speed is not as important." So **`--fast` is rarely the right choice here.** Reach for it only when you are throughput-bound on large batches of clean, horizontal, common-language printed text and can accept lower accuracy.

> Sources: Apple, [*Locating and displaying recognized text*](https://developer.apple.com/documentation/vision/locating-and-displaying-recognized-text) ("The fast path is similar to a traditional OCR approach, and the accurate path uses a neural network… Depending on the recognition level and language correction settings, the available recognition languages change."); WWDC 2019 session 234, [*Text Recognition in Vision Framework*](https://developer.apple.com/videos/play/wwdc2019/234/).

### Output formats

| Format | Streams? | Use when |
|--------|----------|----------|
| `text` | ✓ | You just want text. Multi-result runs are separated by `==> name <==` headers (multi-page sources show `==> name (page 1/3) <==`). |
| `jsonl` | ✓ | PDFs, batches, heavy jobs. One JSON object per line, emitted as each page/image completes. |
| `json`  | ✗ | A downstream tool needs one parseable array. Buffers everything in memory — avoid for large inputs. |

### Writing to files

By default results go to stdout. Pass `-o, --output <dest>` to write files instead:

| Form | Example | Result |
|------|---------|--------|
| Fixed path | `-o notes.txt` | One file (single input only) |
| Directory | `-o out/` | `out/<input>.txt` (or `.json`/`.jsonl`) per input |
| Template | `-o '[dir]/[name].txt'` | Rendered per input — e.g. a `.txt` **next to** each input |

Template placeholders:

| Placeholder | Value |
|-------------|-------|
| `[name]` | Input filename **without** extension (`scan`) |
| `[ext]` | Input filename extension, **without** the dot (`pdf`) |
| `[dir]` | Input directory, no trailing slash (empty for URL/stdin/current dir) |
| `[page]` | 1-based page number. Including it writes **one file per page** instead of one per input |
| `[pagecount]` | Total page count |

Always quote template arguments: `[…]` is a glob character class in zsh (and matches files in bash), so an unquoted `-o [name].txt` fails with "no matches found" or expands unexpectedly.

**Text vs. Markdown:** the written content is the recognized text itself (or JSON, for `--format json`/`jsonl`). `mac-ocr` does **not** generate structured/formatted Markdown — a `.md` extension simply stores that plain text in a Markdown file. Fixed paths and templates accept **any extension** (`.txt`, `.md`, `.text`, …):

```sh
mac-ocr scan.pdf -o notes.md            # recognized text → notes.md
mac-ocr scans/*.pdf -o '[name].md'      # one .md per input
```

Directory mode uses the format's default extension (`.txt`, `.json`, or `.jsonl`); use a fixed path or a template for any other extension.

## Output schema

With `--format json` or `--format jsonl`, each result (one per image, or per PDF page) has this shape. `json` wraps all results in a single array; `jsonl` emits one object per line as each completes.

```jsonc
{
  // Where the input came from — a tagged union:
  //   { "type": "file", "path": "..." } | { "type": "url", "url": "..." } | { "type": "stdin" }
  "source": { "type": "file", "path": "scan.pdf" },

  "page": 1,          // 1-based page index (always 1 for images)
  "pageCount": 3,     // total pages (always 1 for images)
  "width": 1224,      // display-oriented pixel width (honors EXIF orientation)
  "height": 1584,     // display-oriented pixel height

  "text": "Line one\nLine two",   // every observation's text joined by newlines

  "observations": [
    {
      "text": "Line one",                 // top candidate string
      "confidence": 1.0,                   // 0–1
      "boundingBox": {                     // normalized 0–1, top-left origin
        "x": 0.05, "y": 0.42,
        "width": 0.37, "height": 0.06
      },
      "candidates": [                      // only when --max-candidates > 1; length ≤ that
        { "text": "Line one", "confidence": 1.0 },
        { "text": "Line orie", "confidence": 0.3 }
      ],
      "requestRevision": 3                 // Vision model revision that produced it
    }
  ]
}
```

`observations` is empty when no text is found (the run still exits `0`).

### Coordinates

Bounding boxes are **normalized to `0–1` with a top-left origin** (x increases right, y increases down) — the same convention as image pixels and CSS. Apple Vision's native space is normalized but *bottom-left* origin; `mac-ocr` flips the Y axis so every coordinate it emits is top-left. The `--roi <x,y,w,h>` option uses this same space (validated so `x+w ≤ 1` and `y+h ≤ 1`).

Convert to pixels with the result's `width`/`height`:

```js
const px = obs.boundingBox.x * result.width
const py = obs.boundingBox.y * result.height
const pw = obs.boundingBox.width * result.width
const ph = obs.boundingBox.height * result.height
```

## searchable-pdf

Writes a PDF that looks identical to the source but carries an invisible, selectable OCR text layer. By default, each input writes its own searchable PDF; pass `--merge` to combine inputs into one PDF.

```sh
mac-ocr searchable-pdf scan.pdf                      # writes scan.ocr.pdf
mac-ocr searchable-pdf *.pdf                          # writes <name>.ocr.pdf for each
mac-ocr searchable-pdf scan.pdf -o out/               # out/scan.ocr.pdf
mac-ocr searchable-pdf scan.pdf -o '[name]-ocr.pdf'   # scan-ocr.pdf
mac-ocr searchable-pdf scan.pdf -o -                  # PDF to stdout
mac-ocr searchable-pdf --merge -o lease.pdf page1.jpg page2.jpg
```

By default, one input produces one output PDF. With `--merge`, all inputs are combined into one PDF in the exact argument order provided; `mac-ocr` does not sort or reorder pages. Merged mode expects file/URL inputs and does not support stdin input.

- **PDF inputs**: in non-merge mode, each original page is preserved verbatim (vector content is not re-rasterized); only the text layer is added, and pages that already have selectable text are left untouched. The page is rasterized internally to run OCR. Merged output always rewrites pages into a new PDF, so annotations, outlines, and document metadata are not preserved in merged PDFs.
- **Image inputs**: one page, sized from embedded DPI metadata when available. Images without usable DPI metadata fall back to 72 DPI (1px = 1pt).
- **stdin** (`-`) requires an explicit `-o` (no filename to derive a name from).

For image inputs, `--image-quality <0–1>` re-encodes the visible image layer at that quality before placing the invisible text layer. OCR still runs against the original full-resolution decoded image, so this does not lower recognition quality. PDF inputs are not recompressed.

Use `--image-page-dpi <36–2400>` to override image input page sizing when scanner DPI metadata is missing or wrong. This does not change the image pixels used for OCR. `--pdf-dpi` is separate: it controls how PDF pages are rasterized internally before OCR.

Use `--image-downsample-dpi <36–2400>` to cap the visible image layer resolution for image inputs after page size is known. This can reduce output size while keeping OCR on the original pixels and preserving page size. PDF inputs are not downsampled.

In non-merge mode, when **no** page needs OCR — a fully born-digital PDF — the input is copied through **byte-for-byte**: annotations (links, form fields), outlines, and metadata are all preserved, and the output is identical to the input. When at least one page needs OCR, or when `--merge` is used, the document is rewritten: page content (vector text, images) is preserved, but annotations, outlines, and document metadata are **not** carried over. Keep born-digital PDFs with fillable forms or heavy linking out of `searchable-pdf` unless you need the rewrite.

The "already has text" check is page-level: a scanned page carrying one small digital element (a Bates stamp, fax header, or page number) counts as born-digital and is skipped, leaving its scanned body unsearchable. Two caveats:

- `--ocr-all-pages` disables the skip and OCRs every page. Existing digital text may then appear twice in copy/search — that's the trade-off, and why it isn't the default.
- The check scans only the page's own content stream; born-digital text drawn inside a referenced Form XObject isn't detected, so such pages get OCR'd and their text is duplicated by the invisible layer.

### `-o` / `--output`

| Value | Result |
|---|---|
| *(omitted)* | per-input, `[dir]/[name].ocr.pdf` alongside each input |
| `[name]…` template | per-input, custom (`[name]`, `[dir]`, `[ext]`) |
| `dir/` or existing dir | per-input → `<dir>/[name].ocr.pdf` |
| fixed path | single input → that file |
| `-` | single input → stdout (refused on a terminal) |
| fixed path or `-`, with ≥2 inputs | error — use a directory or `[name]` template |

With `--merge`, `-o <file.pdf>` and `-o -` are allowed for multiple inputs. Directory and template outputs are rejected because merged mode writes exactly one PDF.

Also accepts `--ocr-all-pages` (above), `--merge`, `--image-quality <0–1>`, `--image-page-dpi <36–2400>`, `--image-downsample-dpi <36–2400>`, and the recognition options shared with OCR: `--fast`, `--password`, `-l/--language`, `-c/--confidence`, `-w/--custom-words`, `--custom-words-file`, `--no-language-correction`, `--min-text-height`, `--pdf-dpi`, `--roi`.

### Progress and status

Status is **interactive-only** and goes to **stderr**, so stdout stays a clean data channel — `-o -` and pipes are never corrupted.

- On an interactive terminal, a live per-page counter (`scan.pdf  [3/12]`, with a `[i/N]` prefix for multi-input batches) updates in place, then resolves to `scan.pdf → scan.ocr.pdf` when the file is written.
- When stderr is redirected (a pipe, a file, CI logs), successful runs are completely silent — stderr carries only real errors. There is no `--quiet` flag because piped runs are already quiet.

The `ocr` command shows the same live counter for long runs, whenever the results aren't already streaming to that same terminal: with `-o` file output, with stdout redirected, or with buffered `--format json`. When text is scrolling on the terminal, the text itself is the progress.

## languages

List the recognition languages Vision supports on this macOS version (BCP-47 codes, one per line). They apply to both OCR and `searchable-pdf`.

```sh
mac-ocr languages           # accurate recognizer
mac-ocr languages --fast    # fast recognizer's set
```

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success (even if no text was found) |
| `1` | Runtime error (missing file, unreadable input, partial batch failure) |
| `64` | Invalid flag value |

## Machine-readable errors

Set `MAC_OCR_ERROR_FORMAT=json` and open file descriptor 3 to receive a JSON error envelope on fd 3. Intended for programmatic callers; normal stderr text is unchanged.

```jsonc
{
  "schema": "mac-ocr.error",
  "schemaVersion": 1,        // consumers should require this exact version
  "kind": "runtime",         // usage | unavailable | runtime | internal
  "code": "batch_failed",    // machine-readable code
  "message": "one or more inputs failed",
  "exitCode": 1,
  "command": "ocr",          // optional
  "requires": "macOS 26+"    // optional; set when kind is "unavailable"
}
```

Keys are emitted in sorted order (byte-deterministic across runs).
