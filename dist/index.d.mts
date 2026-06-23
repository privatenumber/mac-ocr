/** Image or PDF bytes. Read files or fetch URLs in your own code and pass the bytes. */
type Input = Buffer | Uint8Array | ArrayBuffer;
/** Normalized 0–1 rectangle, top-left origin. */
type BoundingBox = {
    x: number;
    y: number;
    width: number;
    height: number;
};
type TextCandidate = {
    text: string;
    confidence: number;
};
type Observation = {
    /** Best candidate string. */
    text: string;
    /** Confidence, 0–1. */
    confidence: number;
    /** Normalized 0–1 bounding box, top-left origin. */
    boundingBox: BoundingBox;
    /**
     * Alternative readings, length ≤ `maxCandidates`. Present only when
     * `maxCandidates > 1` — at the default the lone candidate would just
     * duplicate `text`/`confidence`.
     */
    candidates?: TextCandidate[];
    /** Vision request revision that produced this observation. */
    requestRevision: number;
};
/** OCR result for a single image or PDF page. */
type OcrResult = {
    /** 1-based page index (always 1 for images). */
    page: number;
    /** Total page count (always 1 for images). */
    pageCount: number;
    /** Display-oriented pixel width (honors EXIF orientation). */
    width: number;
    /** Display-oriented pixel height. */
    height: number;
    /** Every observation's text joined by newlines. */
    text: string;
    observations: Observation[];
};
/**
 * Region of interest in normalized top-left-origin coordinates. Accepts an
 * object `{ x, y, width, height }`, a tuple `[x, y, width, height]`, or a
 * `"x,y,width,height"` string. Structured forms are validated before spawn.
 */
type RegionOfInterest = BoundingBox | readonly [x: number, y: number, width: number, height: number] | string;
/** Options shared by `ocr` and `createSearchablePdf`. */
type CommonOptions = {
    /** Use fast recognition (lower accuracy, much faster). */
    fast?: boolean;
    /** Recognition languages (BCP-47, e.g. `['en-US', 'ja-JP']`). */
    languages?: string[];
    /** Drop observations below this confidence (0–1). */
    confidence?: number;
    /** Custom vocabulary words to bias recognition toward. */
    customWords?: string[];
    /** Language correction. Default `true`; set `false` to disable. */
    languageCorrection?: boolean;
    /** Ignore text shorter than this fraction of image height (0–1). */
    minTextHeight?: number;
    /** Restrict recognition to a sub-rectangle of the image. */
    regionOfInterest?: RegionOfInterest;
    /** PDF rasterization DPI. `'auto'` (default) or an integer 72–600. */
    pdfDpi?: number | 'auto';
    /** Password for an encrypted PDF (falls back to `MAC_OCR_PDF_PASSWORD`). */
    password?: string;
    /** Abort the underlying subprocess. */
    signal?: AbortSignal;
};
/** Options for {@link ocr} and {@link ocr.pages}. */
type OcrOptions = CommonOptions & {
    /** Maximum text candidates per observation (1–10). Default 1. */
    maxCandidates?: number;
};
/** Options for {@link createSearchablePdf}. */
type SearchablePdfOptions = CommonOptions & {
    /**
     * OCR every page, including pages that already have selectable text
     * (skipped by default). Use for hybrid pages — a scan plus a small digital
     * stamp or page number — at the cost of existing digital text appearing
     * twice in copy/search.
     */
    ocrAllPages?: boolean;
    /**
     * Visible image layer quality for image inputs (`0`–`1`). OCR still uses the
     * original full-resolution image. PDF inputs are not recompressed.
     */
    imageQuality?: number;
    /**
     * DPI to use for image input page sizing. OCR still uses the original
     * full-resolution image. PDF inputs are not affected.
     */
    imagePageDpi?: number;
    /**
     * Maximum DPI for the visible image layer of image inputs. OCR and page size
     * are not affected. PDF inputs are not downsampled.
     */
    imageDownsampleDpi?: number;
};

/**
 * Result of `ocr.pages()`: iterate it to stream pages as they finish, or
 * collect them with `Array.fromAsync(ocr.pages(bytes))`.
 *
 * Single-use: nothing spawns until the first iteration step, and a consumed
 * result throws a `usage`-kind error on re-iteration — call `ocr.pages()`
 * again to re-read the input.
 */
type OcrPages = AsyncIterable<OcrResult>;
/**
 * Recognize text in image or single-page-PDF bytes.
 *
 * ```ts
 * const result = await ocr(await fs.readFile('receipt.jpg'))
 * console.log(result.text)
 * ```
 *
 * For multi-page PDFs, use {@link ocr.pages} — iterate it to stream, or
 * collect every page with `Array.fromAsync`:
 *
 * ```ts
 * for await (const page of ocr.pages(await fs.readFile('book.pdf'))) {
 *   console.log(page.page, page.text)
 * }
 * const pages = await Array.fromAsync(ocr.pages(await fs.readFile('book.pdf')))
 * ```
 */
declare const ocr: ((input: Input, options?: OcrOptions) => Promise<OcrResult>) & {
    pages: (input: Input, options?: OcrOptions) => OcrPages;
};

/**
 * Produce a searchable PDF from image or PDF bytes — the same content with an
 * invisible, selectable OCR text layer added. Returns the PDF bytes.
 *
 * ```ts
 * const pdf = await createSearchablePdf(await fs.readFile('scan.pdf'))
 * await fs.writeFile('scan.ocr.pdf', pdf)
 * ```
 */
declare const createSearchablePdf: (input: Input, options?: SearchablePdfOptions) => Promise<Uint8Array>;

/**
 * List the recognition languages supported on this macOS version (BCP-47
 * codes, e.g. `en-US`). These apply to both {@link ocr} and
 * {@link createSearchablePdf} — they share the same Vision recognizer. Pass
 * `{ fast: true }` for the set available to the fast recognizer.
 */
declare const supportedLanguages: (options?: {
    fast?: boolean;
}) => Promise<string[]>;

/** Category of failure, mirrored from the CLI's machine-error envelope. */
type MacOcrErrorKind = 'usage' | 'unavailable' | 'runtime' | 'internal' | 'spawn' | 'parse' | 'abort';
/** Structured error envelope emitted by the CLI on file descriptor 3. */
type MacOcrErrorEnvelope = {
    schema: 'mac-ocr.error';
    schemaVersion: 1;
    kind: 'usage' | 'unavailable' | 'runtime' | 'internal';
    code: string;
    message: string;
    exitCode: number;
    command?: string;
    requires?: string;
};
type MacOcrErrorOptions = {
    kind: MacOcrErrorKind;
    /** Machine-readable error code from the CLI (e.g. `usage_error`), when available. */
    code?: string;
    /** Process exit code, or `null` when killed by a signal / never started. */
    exitCode?: number | null;
    /** Captured stderr from the CLI. */
    stderr?: string;
    cause?: unknown;
};
/**
 * A failure from the `mac-ocr` binary. Inspect `kind` to branch on the failure
 * category (e.g. `'usage'` for bad input, `'unavailable'` when a feature needs
 * a newer macOS), and `stderr` for the human-readable CLI message.
 */
declare class MacOcrError extends Error {
    readonly kind: MacOcrErrorKind;
    readonly code?: string;
    readonly exitCode: number | null;
    readonly stderr: string;
    constructor(message: string, options: MacOcrErrorOptions);
}

export { MacOcrError, createSearchablePdf, ocr, supportedLanguages };
export type { BoundingBox, CommonOptions, Input, MacOcrErrorEnvelope, MacOcrErrorKind, Observation, OcrOptions, OcrPages, OcrResult, RegionOfInterest, SearchablePdfOptions, TextCandidate };
