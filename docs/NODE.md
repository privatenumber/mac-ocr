# Node.js API

`mac-ocr` ships a typed, promise-based API that spawns the bundled CLI binary (no native addon). macOS only; ESM only (Node ≥ 22).

```sh
npm install mac-ocr
```

```ts
import { ocr, createSearchablePdf, supportedLanguages } from 'mac-ocr'
```

## Input

Every function takes image or PDF **bytes** — a `Buffer`, `Uint8Array`, or `ArrayBuffer`. Images can be any format macOS decodes (PNG, JPEG, TIFF, HEIC, GIF, BMP, …). Read files or fetch URLs in your own code and pass the bytes; the API does no file/URL I/O itself. A non-bytes input throws a `TypeError`.

```ts
import fs from 'node:fs/promises'
const result = await ocr(await fs.readFile('receipt.jpg'))
```

## `ocr(input, options?)`

Recognizes text in a single image or single-page PDF. Returns `Promise<OcrResult>`.

```ts
const { text, observations, width, height } = await ocr(bytes)
```

Throws a `MacOcrError` (`kind: 'usage'`) if `input` is a **multi-page** PDF — use `ocr.pages` for those.

## `ocr.pages(input, options?)`

OCRs every page of a (possibly multi-page) PDF. The return value is a plain `AsyncIterable<OcrResult>`:

```ts
// Stream pages as each finishes — bounded memory, early results:
for await (const page of ocr.pages(pdfBytes)) {
  console.log(page.page, '/', page.pageCount, page.text)
}

// …or collect all pages into an array:
const pages = await Array.fromAsync(ocr.pages(pdfBytes))   // OcrResult[]
```

Works on single-page inputs too (yields one result). The subprocess only spawns when iteration starts, and each returned value can be consumed once — call `ocr.pages()` again to re-read. If the CLI exits cleanly but any announced page failed to arrive (an unparseable line), the iteration throws a `parse`-kind error rather than silently dropping pages.

## `createSearchablePdf(input, options?)`

Produces a searchable PDF — the same content with an invisible, selectable OCR text layer — and returns its bytes as a `Promise<Uint8Array>`.

```ts
const pdf = await createSearchablePdf(scanBytes)
await fs.writeFile('scan.ocr.pdf', pdf)
```

Born-digital pages keep their existing text; image/scanned pages get the layer. A fully born-digital PDF is returned byte-for-byte (annotations, links, form fields, and outlines preserved); when any page needs OCR, the rewrite preserves page content but not annotations or outlines. The full PDF is returned at once (it is not streamed).

## `supportedLanguages(options?)`

Lists the recognition languages Vision supports on this macOS version (BCP-47 codes). They apply to both `ocr` and `createSearchablePdf`. Returns `Promise<string[]>`.

```ts
const languages = await supportedLanguages()              // accurate recognizer
const fastLanguages = await supportedLanguages({ fast: true })
```

## Options

`ocr`, `ocr.pages`, and `createSearchablePdf` share these (all optional):

| Option | Type | Effect |
|---|---|---|
| `fast` | `boolean` | Use the faster character-by-character recognizer instead of the default neural net — lower accuracy; see [Recognition levels](CLI.md#recognition-levels) |
| `languages` | `string[]` | Recognition languages (BCP-47), e.g. `['en-US', 'ja-JP']`. Validated by the CLI against `supportedLanguages()` — unsupported codes reject with a `usage`-kind error |
| `confidence` | `number` | Drop observations below this confidence (`0`–`1`) |
| `customWords` | `string[]` | Custom vocabulary to bias recognition toward |
| `languageCorrection` | `boolean` | Language correction (default `true`) |
| `minTextHeight` | `number` | Ignore text shorter than this fraction of image height (`0`–`1`) |
| `regionOfInterest` | object \| tuple \| string | Restrict recognition to a sub-rectangle (see below) |
| `pdfDpi` | `number \| 'auto'` | PDF rasterization DPI (`'auto'` default, or `72`–`600`) |
| `password` | `string` | Password for an encrypted PDF (falls back to `MAC_OCR_PDF_PASSWORD`). Forwarded to the CLI via the env var, never `argv`, so it stays out of the process list |
| `signal` | `AbortSignal` | Abort the underlying subprocess |

`ocr` and `ocr.pages` additionally accept:

| Option | Type | Effect |
|---|---|---|
| `maxCandidates` | `number` | Alternative text candidates per observation (`1`–`10`, default `1`) |

`createSearchablePdf` additionally accepts:

| Option | Type | Effect |
|---|---|---|
| `ocrAllPages` | `boolean` | OCR every page, including pages that already have selectable text (skipped by default). For hybrid scan-plus-stamp pages; existing digital text may appear twice in copy/search |
| `ocrStrategy` | `'auto' \| 'standard' \| 'partitioned'` | Searchable PDF OCR strategy. Default `auto`; use `standard` to force full-page OCR only, or `partitioned` to force the recursive partitioned pass for eligible pages |
| `imageQuality` | `number` | Visible image layer quality for image inputs (`0`–`1`). OCR still uses the original full-resolution image; PDF inputs are not recompressed |
| `imagePageDpi` | `number` | DPI to use for image input page sizing. OCR still uses the original full-resolution image; PDF inputs are not affected |
| `imageDownsampleDpi` | `number` | Maximum DPI for the visible image layer of image inputs. OCR and page size are not affected; PDF inputs are not downsampled |

`supportedLanguages` accepts only `{ fast?: boolean }`.

### `regionOfInterest`

Normalized, top-left origin. Three accepted forms:

```ts
{ x: 0, y: 0, width: 1, height: 0.5 }   // object
[0, 0, 1, 0.5]                          // tuple: [x, y, width, height]
'0,0,1,0.5'                             // string
```

Object/tuple forms are validated before the subprocess spawns (throws `RangeError`/`TypeError` on out-of-range or malformed values).

## Result types

```ts
type OcrResult = {
  page: number          // 1-based page index (always 1 for images)
  pageCount: number     // total page count (always 1 for images)
  width: number         // display-oriented pixel width (honors EXIF orientation)
  height: number        // display-oriented pixel height
  text: string          // every observation's text joined by newlines
  observations: Observation[]
}

type Observation = {
  text: string                                          // best candidate
  confidence: number                                    // 0–1
  boundingBox: BoundingBox                              // normalized 0–1, top-left origin
  candidates?: { text: string; confidence: number }[]  // only when maxCandidates > 1
  requestRevision: number                               // Vision model revision
}

type BoundingBox = { x: number; y: number; width: number; height: number }
```

Bounding boxes are normalized `0`–`1`, top-left origin. Convert to pixels by multiplying by the result's `width`/`height` — see [Coordinates](./CLI.md#coordinates).

## Errors

Failures throw a `MacOcrError`:

```ts
import { MacOcrError } from 'mac-ocr'

try {
  await ocr(bytes)
} catch (error) {
  if (error instanceof MacOcrError) {
    error.kind      // category — see below
    error.code      // machine-readable code from the CLI, when available
    error.exitCode  // process exit code, or null (signal/never-started)
    error.stderr    // captured CLI stderr
  }
}
```

| `kind` | When |
|---|---|
| `usage` | Bad input/options (exit 64), or a multi-page PDF passed to `ocr()` (detected by the wrapper — `exitCode` is `null`) |
| `unavailable` | A feature isn't available on this macOS version |
| `runtime` | Recognition or I/O failure, or the binary was killed by a signal that wasn't your `AbortSignal` |
| `internal` | An unexpected CLI failure |
| `abort` | Cancelled via your `AbortSignal` — never anything else |
| `spawn` | The binary couldn't be started |
| `parse` | The binary's output couldn't be parsed, or pages were missing — `ocr.pages()` verifies every page announced by `pageCount` actually arrived |

## Cancellation

```ts
const controller = new AbortController()
setTimeout(() => controller.abort(), 5_000)
await ocr(bytes, { signal: controller.signal })   // rejects with MacOcrError, kind 'abort'
```

## Tree-shaking

The package is side-effect free (`"sideEffects": false`), so a bundler's dead-code elimination keeps only what you import — e.g. importing just `supportedLanguages` won't retain the OCR or searchable-PDF code.

See the [CLI reference](./CLI.md) for the underlying command behavior, output schema, and coordinate system.
