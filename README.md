<p align="center">
	<img src=".github/logo.webp" width="200" alt="mac-ocr logo">
</p>

<h1 align="center">mac-ocr</h1>

<p align="center">
	A macOS command-line tool that reads text from images and PDFs, and creates searchable PDFs.<br>
	Runs entirely on your Mac with Apple's <a href="https://developer.apple.com/documentation/vision">Vision framework</a>; nothing is uploaded.
</p>

> [!TIP]
> Useful for AI agents too: instead of spending vision tokens reading documents, an agent can run `mac-ocr` locally for free. A [skill](#agent-skills) is bundled so agents know how to use it.

### Features

- **Read text from an image:** `mac-ocr photo.png`
- **Read text from many images:** `mac-ocr *.png`
- **Stream text from a PDF, page by page:** `mac-ocr scan.pdf --format jsonl`
- **Turn an image into a searchable PDF:** `mac-ocr searchable-pdf photo.png` → `photo.ocr.pdf`
- **Add a selectable text layer to a scanned PDF:** `mac-ocr searchable-pdf scan.pdf` → `scan.ocr.pdf`

## Install

```sh
npm install -g mac-ocr
```

Or run it without installing:

```sh
npx mac-ocr receipt.jpg
```

**Requirements:** macOS 10.15+. The npm package ships a prebuilt universal binary, so no Xcode or Swift toolchain is needed.

## Recognize text

OCR is the default action — you don't need a subcommand:

```sh
mac-ocr receipt.jpg                 # text → stdout
mac-ocr page1.png page2.png         # multiple images
mac-ocr scan.pdf                    # multi-page PDF
cat screenshot.png | mac-ocr        # stdin
mac-ocr https://example.com/a.png   # URL (simple GET)
```

Default output is plain text. Use JSON when you need bounding boxes, confidence, or page metadata:

```sh
mac-ocr receipt.jpg --format json
mac-ocr document.pdf --format jsonl   # one JSON object per page, streamed
```

PDF pages stream as they're recognized, so with a large document you see the first page's text right away.

### Save text to files

```sh
mac-ocr ~/Screenshots/*.png -o '[dir]/[name].txt'   # a .txt next to each image
mac-ocr scan.pdf -o notes.md                        # recognized text to a chosen .txt/.md file
mac-ocr receipts/*.pdf -o out/                      # one file per input in out/
grep -rli "invoice" ~/Screenshots                    # then search with normal tools
```

`-o` takes a file, a directory (`out/`), or a filename template ([all placeholders](docs/CLI.md#writing-to-files)). Quote templates, since `[…]` is a glob pattern in zsh. Whatever the extension, the content is the plain recognized text.

## Create a searchable PDF

`searchable-pdf` takes a PDF or an image and writes a PDF that looks identical to the source but whose text is selectable and searchable. By default it writes `[name].ocr.pdf` next to each input — one searchable PDF per input:

```sh
mac-ocr searchable-pdf scan.pdf            # writes scan.ocr.pdf
mac-ocr searchable-pdf photo.jpg            # image → one-page photo.ocr.pdf
mac-ocr searchable-pdf *.pdf                # writes <name>.ocr.pdf for each
mac-ocr searchable-pdf --merge -o lease.pdf page1.jpg page2.jpg
```

Use `-o` to control the destination — a directory, a `[name]` template, a fixed file, or `-` for stdout:

```sh
mac-ocr searchable-pdf scan.pdf -o out/              # out/scan.ocr.pdf
mac-ocr searchable-pdf scan.pdf -o '[name]-ocr.pdf'  # scan-ocr.pdf
mac-ocr searchable-pdf scan.pdf -o searchable.pdf    # fixed path
mac-ocr searchable-pdf scan.pdf -o - > scan.pdf      # stdout
```

A fixed path or `-` (stdout) takes a single input in non-merge mode; for multiple per-input outputs use a directory or a `[name]` template.

Pass `--merge` to combine multiple file/URL inputs into one searchable PDF. Merged pages follow the exact argument order you pass; `mac-ocr` never sorts or reorders inputs.

Image inputs are sized from embedded DPI metadata when available. Images without usable DPI metadata fall back to 72 DPI (1px = 1pt).

### Partitioned OCR

Searchable PDFs use `--ocr-strategy auto` by default. Vision can miss small labels when it analyzes a full high-resolution page at once, even though the same text is readable in a tighter crop. Auto mode starts with full-page OCR, then runs a partitioned pass only for large pages with small or missing text: it recursively splits regions along their longer axis until text is large enough or the region is below the calibrated size floor.

In dogfooding on a high-resolution five-page scan, partitioned OCR recovered small form labels the full-page pass missed while keeping the generated PDF around 7 MB. Large partitioned runs may take longer because Vision processes regions serially. Use `--ocr-strategy standard` to opt out, or `--ocr-strategy partitioned` to force the partitioned pass for eligible pages. Auto mode skips partitioning when `--roi` is set; forced `partitioned` mode cannot be combined with `--roi`.

In non-merge mode, pages that already have selectable text are skipped — only scanned pages get OCR. A PDF that needs no OCR at all passes through unchanged. To OCR every page regardless, pass `--ocr-all-pages`. The finer points (what survives a rewrite, how "already has text" is decided) are in [docs/CLI.md](docs/CLI.md#searchable-pdf).

In an interactive terminal you get a live `[page/total]` progress counter. Piped or redirected runs are silent on success, so scripts stay clean.

## Options

Both OCR and `searchable-pdf` accept the recognition options:

| Flag | Effect |
|------|--------|
| `--fast` | Faster, lower-accuracy recognition ([details](docs/CLI.md#recognition-levels)) |
| `--password <password>` | Password for an encrypted PDF (or set `MAC_OCR_PDF_PASSWORD`) |
| `-l, --language <code>` | Recognition language (BCP-47, repeatable). e.g. `-l en-US -l ja-JP` |
| `-c, --confidence <0–1>` | Drop observations below this confidence |
| `-w, --custom-words <word>` | Add custom vocabulary (repeatable) |
| `--custom-words-file <path>` | Custom vocabulary file, one word per line |
| `--no-language-correction` | Disable language correction |
| `--min-text-height <0–1>` | Ignore text shorter than this fraction of image height |
| `--pdf-dpi <auto\|72–600>` | PDF rasterization DPI (default `auto`) |
| `--roi <x,y,w,h>` | Region of interest: restrict recognition to a normalized region (top-left origin) |

### `mac-ocr <file>`

| Flag | Effect |
|------|--------|
| `-f, --format <text\|json\|jsonl>` | Output format (default `text`) |
| `-o, --output <path>` | Output path, directory, or template (`[name]`, `[ext]`, `[dir]`, `[page]`). Default: stdout. Any extension — e.g. `.txt` or `.md`. |
| `--max-candidates <1–10>` | Alternative text candidates per observation |

### `mac-ocr searchable-pdf <file>`

| Flag | Effect |
|------|--------|
| `-o, --output <dest>` | Output path, `[name]` template, directory, or `-` for stdout. Default: `[name].ocr.pdf` next to each input. |
| `--ocr-all-pages` | OCR every page, including pages that already have selectable text (skipped by default) |
| `--ocr-strategy <auto\|standard\|partitioned>` | Searchable PDF OCR strategy. `auto` may run a partitioned second pass for large pages with small text; `standard` uses full-page OCR only. |
| `--merge` | Combine inputs into one searchable PDF in argument order. Requires `-o <file.pdf>` or `-o -`. |
| `--image-quality <0–1>` | Visible image layer quality for image inputs. OCR still uses the original full-resolution image; PDF inputs are not recompressed. |
| `--image-page-dpi <36–2400>` | DPI to use for image input page sizing. OCR still uses the original full-resolution image; PDF inputs are unaffected. |
| `--image-downsample-dpi <36–2400>` | Maximum DPI for the visible image layer of image inputs. OCR and page size are unaffected; PDF inputs are not downsampled. |

List the recognition languages available on your macOS version with `mac-ocr languages` (add `--fast` for the fast recognizer's set).

See [docs/CLI.md](docs/CLI.md) for the full reference — every command and flag, plus the JSON output schema.

## Node.js API

The same package exposes a typed, promise-based API that wraps the binary. Inputs are image or PDF **bytes** — read files or fetch URLs in your own code and pass the bytes:

```sh
npm install mac-ocr
```

```ts
import fs from 'node:fs/promises'
import { ocr, createSearchablePdf, supportedLanguages } from 'mac-ocr'

// Recognize text in an image or single-page PDF
const result = await ocr(await fs.readFile('receipt.jpg'))
console.log(result.text)
for (const { text, confidence, boundingBox } of result.observations) { /* … */ }

// Multi-page PDF: stream pages as they finish…
for await (const page of ocr.pages(await fs.readFile('book.pdf'))) {
    console.log(page.page, '/', page.pageCount, page.text)
}
// …or collect the whole thing into an array
const pages = await Array.fromAsync(ocr.pages(await fs.readFile('book.pdf')))

// Build a searchable PDF (returns the PDF bytes)
const pdf = await createSearchablePdf(await fs.readFile('scan.pdf'), { fast: true })
await fs.writeFile('scan.ocr.pdf', pdf)

// Recognition languages supported on this macOS version (for ocr and createSearchablePdf)
const languages = await supportedLanguages()
```

Options mirror the CLI flags (like `{ fast: true }` above), plus an `AbortSignal` for cancellation. Failures throw a `MacOcrError` with a `kind` you can branch on. See [docs/NODE.md](docs/NODE.md) for every option, the result types, and error handling.

## How it works

`mac-ocr` is a native Swift binary built on Apple's Vision framework (`VNRecognizeTextRequest`). Recognition happens entirely on-device — nothing is uploaded. The searchable-PDF layer is invisible text drawn with Core Graphics + Core Text, placed word by word where Vision found each word.

## Agent Skills

The package bundles an [agent skill](https://agentskills.io) covering the CLI and Node API — set up [`skills-npm`](https://github.com/antfu/skills-npm) in your project and coding agents discover it automatically.
