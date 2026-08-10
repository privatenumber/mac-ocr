/** Image or PDF bytes. Keep them unchanged until the consuming operation finishes. */
export type Input = Buffer | Uint8Array | ArrayBuffer;

/** Normalized 0–1 rectangle, top-left origin. */
export type BoundingBox = {
	x: number;
	y: number;
	width: number;
	height: number;
};

export type TextCandidate = {
	text: string;
	confidence: number;
};

export type Observation = {

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
export type OcrResult = {

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
 * `"x,y,width,height"` string. Structured forms are validated by Node before OCR begins.
 */
export type RegionOfInterest =
	| BoundingBox
	| readonly [x: number, y: number, width: number, height: number]
	| string;

/** Options shared by `ocr` and `createSearchablePdf`. */
export type CommonOptions = {

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

	/** Abort this operation. */
	signal?: AbortSignal;
};

/** Options for {@link ocr} and {@link ocr.pages}. */
export type OcrOptions = CommonOptions & {

	/** Maximum text candidates per observation (1–10). Default 1. */
	maxCandidates?: number;
};

/** Options for {@link createSearchablePdf}. */
export type SearchablePdfOptions = CommonOptions & {

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

	/** OCR strategy for searchable PDFs. Default `'auto'`. */
	ocrStrategy?: 'auto' | 'standard' | 'partitioned';
};
