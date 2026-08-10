/**
 * `mac-ocr` — OCR and searchable-PDF generation via Apple's Vision framework.
 *
 * The API spawns the bundled CLI binary. Inputs are image or PDF **bytes**
 * (Buffer / Uint8Array / ArrayBuffer); read files or fetch URLs in your own
 * code and pass the bytes.
 *
 * ```ts
 * import { ocr, createSearchablePdf } from 'mac-ocr'
 * import fs from 'node:fs/promises'
 *
 * const { text } = await ocr(await fs.readFile('receipt.jpg'))
 *
 * for await (const page of ocr.pages(await fs.readFile('book.pdf'))) {
 *   console.log(page.page, page.text)
 * }
 *
 * const pdf = await createSearchablePdf(await fs.readFile('scan.pdf'))
 * ```
 */

export { ocr } from './ocr.ts';
export type { OcrPages } from './ocr.ts';
export { createSearchablePdf } from './searchable-pdf.ts';
export { supportedLanguages } from './languages.ts';

export { MacOcrError } from './errors.ts';
export type { MacOcrErrorKind, MacOcrErrorEnvelope } from './errors.ts';

export type {
	Input,
	BoundingBox,
	TextCandidate,
	Observation,
	OcrResult,
	RegionOfInterest,
	CommonOptions,
	OcrOptions,
	SearchablePdfOptions,
} from './types.ts';
