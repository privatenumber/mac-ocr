import { createInterface } from 'node:readline';
import { isMainThread } from 'node:worker_threads';
import { buildArgs } from './args.ts';
import { MacOcrError } from './errors.ts';
import {
	spawnBinary,
	waitForExit,
	type Spawned,
} from './process.ts';
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
export const ocrSingleProcess = async (input: Input, options?: OcrOptions): Promise<OcrResult> => {
	const spawned = spawnOcr(input, options);
	let first: OcrResult | undefined;

	try {
		for await (const line of createInterface({ input: spawned.proc.stdout })) {
			const page = parseLine(line);
			if (page !== undefined) {
				// One page is all we need — its pageCount already tells us
				// whether the input is multi-page, so don't wait for (or OCR)
				// a second page just to find out.
				first = page;
				break;
			}
		}
	} catch (error) {
		await waitForExit(spawned, label); // surface the real failure if there is one
		throw new MacOcrError(`${label} output could not be read`, {
			kind: 'parse',
			cause: error,
		});
	}

	if (first !== undefined && first.pageCount > 1) {
		// Stop the subprocess before it spends time recognizing further pages.
		spawned.proc.kill();
		await spawned.exit.catch(() => {});
		throw new MacOcrError(
			'Input has multiple pages. Use `ocr.pages()` to read them all.',
			{ kind: 'usage' },
		);
	}

	await waitForExit(spawned, label);
	if (first === undefined) {
		throw new MacOcrError(`${label} produced no output`, { kind: 'parse' });
	}
	return first;
};

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
const ocrPages = (input: Input, options?: OcrOptions): OcrPages => {
	let consumed = false;

	const iterate = async function* iterate(): AsyncGenerator<OcrResult> {
		if (consumed) {
			throw new MacOcrError(
				'This ocr.pages() result was already consumed. Call ocr.pages() again to re-read it.',
				{ kind: 'usage' },
			);
		}
		consumed = true;

		const spawned = spawnOcr(input, options);
		let completed = false;
		let yielded = 0;
		let expectedPageCount: number | undefined;
		try {
			for await (const line of createInterface({ input: spawned.proc.stdout })) {
				const page = parseLine(line);
				if (page !== undefined) {
					yielded += 1;
					expectedPageCount = page.pageCount;
					yield page;
				}
			}
			completed = true;
		} finally {
			if (completed) {
				await waitForExit(spawned, label);
			} else {
				// Consumer broke out early — stop the subprocess.
				spawned.proc.kill();
				await spawned.exit.catch(() => {});
			}
		}

		// The CLI exited cleanly: every page must have arrived intact.
		// Unparseable lines are skipped during streaming, so reconcile against
		// pageCount to turn silent page loss into a loud error.
		if (expectedPageCount === undefined) {
			throw new MacOcrError(`${label} produced no output`, { kind: 'parse' });
		}
		if (yielded < expectedPageCount) {
			throw new MacOcrError(
				`${label} produced ${yielded} of ${expectedPageCount} pages — some output could not be parsed`,
				{ kind: 'parse' },
			);
		}
	};

	return { [Symbol.asyncIterator]: iterate };
};

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
