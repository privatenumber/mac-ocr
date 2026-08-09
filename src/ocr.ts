import { isMainThread } from 'node:worker_threads';
import { buildArgs } from './args.ts';
import { createPageAnalysis } from './page-analysis.ts';
import { spawnBinary, type Spawned } from './process.ts';
import { ocrWithService } from './service/index.ts';
import type { Input, OcrOptions, OcrResult } from './types.ts';

const label = 'mac-ocr ocr';

/**
 * Parse one JSONL line into an `OcrResult`, dropping the `source` field — the
 * wrapper always feeds bytes via stdin, so it would always be
 * `{"type":"stdin"}` and carries no information for API consumers.
 *
 * Strict: a JSONL page line starts with `{`. Anything else is skipped, and
 * the page-count reconciliation in `ocr.pages()` turns skipped pages into a
 * loud `parse` error instead of silent loss.
 */
const parseLine = (line: string): OcrResult | undefined => {
	if (!line.startsWith('{')) {
		return undefined;
	}
	let parsed: Record<string, unknown>;
	try {
		parsed = JSON.parse(line) as Record<string, unknown>;
	} catch {
		return undefined;
	}
	const { source, ...result } = parsed;
	return result as unknown as OcrResult;
};

const spawnOcr = (input: Input, options?: OcrOptions): Spawned => spawnBinary(
	['ocr', '--format', 'jsonl', ...buildArgs(options), '-'],
	{
		input,
		signal: options?.signal,
		password: options?.password,
	},
);

/** OCR a single image or single-page PDF. Throws if the input has multiple pages. */
export const ocrSingleProcess = (
	input: Input,
	options?: OcrOptions,
): Promise<OcrResult> => ocrProcessAnalysis.singleProcess(input, options);

const ocrSingle = (input: Input, options?: OcrOptions): Promise<OcrResult> => (
	isMainThread
		? ocrWithService(input, options)
		: ocrSingleProcess(input, options)
);

/**
 * Result of `ocr.pages()`: iterate it to stream pages as they finish, or
 * collect them with `Array.fromAsync(ocr.pages(bytes))`.
 *
 * Single-use: nothing spawns until the first iteration step, and a consumed
 * result throws a `usage`-kind error on re-iteration — call `ocr.pages()`
 * again to re-read the input.
 */
export type OcrPages = AsyncIterable<OcrResult>;

/** OCR every page of a (possibly multi-page) PDF. */
const ocrProcessAnalysis = createPageAnalysis({
	label,
	multiPageMessage: 'Input has multiple pages. Use `ocr.pages()` to read them all.',
	pageReuseMessage: 'This ocr.pages() result was already consumed. Call ocr.pages() again to re-read it.',
	missingPageMessage: (yielded, expected) => (
		`${label} produced ${yielded} of ${expected} pages — some output could not be parsed`
	),
	spawn: spawnOcr,
	parseLine,
});

const ocrPages = (input: Input, options?: OcrOptions): OcrPages => (
	ocrProcessAnalysis.pages(input, options)
);

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
export const ocr = Object.assign(ocrSingle, {
	pages: ocrPages,
});
