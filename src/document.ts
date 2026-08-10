import { createInterface } from 'node:readline';
import { isMainThread } from 'node:worker_threads';
import { buildArgs } from './args.ts';
import { parseOcrDocumentResult } from './document-parser.ts';
import { MacOcrError } from './errors.ts';
import { spawnBinary, waitForExit, type Spawned } from './process.ts';
import { ocrDocumentPagesWithService, ocrDocumentWithService } from './service/index.ts';
import type { Input, OcrDocumentOptions, OcrDocumentResult } from './types.ts';

const label = 'mac-ocr document';

const parseDocumentLine = (line: string): OcrDocumentResult | undefined => {
	if (!line.startsWith('{')) {
		return undefined;
	}
	try {
		return parseOcrDocumentResult(JSON.parse(line) as unknown);
	} catch {
		return undefined;
	}
};

const spawnDocument = (input: Input, options?: OcrDocumentOptions): Spawned => spawnBinary(
	['document', '--format', 'jsonl', ...buildArgs(options), '-'],
	{
		input,
		signal: options?.signal,
		password: options?.password,
	},
);

export type OcrDocumentPages = AsyncIterable<OcrDocumentResult>;

const ocrDocumentSingleProcess = async (
	input: Input,
	options?: OcrDocumentOptions,
): Promise<OcrDocumentResult> => {
	const spawned = spawnDocument(input, options);
	let first: OcrDocumentResult | undefined;

	try {
		for await (const line of createInterface({ input: spawned.proc.stdout })) {
			const page = parseDocumentLine(line);
			if (page !== undefined) {
				first = page;
				break;
			}
		}
	} catch (error) {
		await waitForExit(spawned, label);
		throw new MacOcrError(`${label} output could not be read`, {
			kind: 'parse',
			cause: error,
		});
	}

	if (first !== undefined && first.pageCount > 1) {
		spawned.proc.kill();
		await spawned.exit.catch(() => {});
		throw new MacOcrError(
			'Input has multiple pages. Use `ocrDocument.pages()` to read them all.',
			{ kind: 'usage' },
		);
	}

	await waitForExit(spawned, label);
	if (first === undefined) {
		throw new MacOcrError(`${label} produced no output`, { kind: 'parse' });
	}
	return first;
};

const ocrDocumentPagesSingleProcess = (
	input: Input,
	options?: OcrDocumentOptions,
): OcrDocumentPages => {
	const iterate = async function* iterate(): AsyncGenerator<OcrDocumentResult> {
		const spawned = spawnDocument(input, options);
		let completed = false;
		try {
			for await (const line of createInterface({ input: spawned.proc.stdout })) {
				const page = parseDocumentLine(line);
				if (page === undefined) {
					continue;
				}
				yield page;
			}
			completed = true;
		} finally {
			if (completed) {
				await waitForExit(spawned, label);
			} else {
				spawned.proc.kill();
				await spawned.exit.catch(() => {});
			}
		}
	};

	return { [Symbol.asyncIterator]: iterate };
};

const ocrDocumentSingle = async (
	input: Input,
	options?: OcrDocumentOptions,
): Promise<OcrDocumentResult> => {
	if (!isMainThread) {
		return ocrDocumentSingleProcess(input, options);
	}
	return ocrDocumentWithService(
		input,
		buildArgs(options),
		options?.password || process.env.MAC_OCR_PDF_PASSWORD,
		options?.signal,
	);
};

const ocrDocumentPages = (input: Input, options?: OcrDocumentOptions): OcrDocumentPages => {
	let consumed = false;
	const iterate = async function* iterate(): AsyncGenerator<OcrDocumentResult> {
		if (consumed) {
			throw new MacOcrError(
				'This ocrDocument.pages() result was already consumed. Call ocrDocument.pages() again to re-read it.',
				{ kind: 'usage' },
			);
		}
		consumed = true;

		const stream = isMainThread
			? await ocrDocumentPagesWithService(
				input,
				buildArgs(options),
				options?.password || process.env.MAC_OCR_PDF_PASSWORD,
				options?.signal,
			) as AsyncIterable<OcrDocumentResult> & { cancel: () => Promise<void> }
			: undefined;
		const pages = stream ?? ocrDocumentPagesSingleProcess(input, options);
		let completed = false;
		let expectedPageCount: number | undefined;
		const seenPages = new Set<number>();
		let invalidPageMetadata = false;
		try {
			for await (const page of pages) {
				if (
					(expectedPageCount !== undefined && page.pageCount !== expectedPageCount)
					|| seenPages.has(page.page)
				) {
					invalidPageMetadata = true;
					continue;
				}
				expectedPageCount = page.pageCount;
				seenPages.add(page.page);
				yield page;
			}
			completed = true;
		} finally {
			if (!completed && stream) {
				await stream.cancel();
			}
		}

		if (expectedPageCount === undefined) {
			throw new MacOcrError(`${label} produced no output`, { kind: 'parse' });
		}
		if (invalidPageMetadata || seenPages.size !== expectedPageCount) {
			throw new MacOcrError(
				`${label} produced ${seenPages.size} of ${expectedPageCount} pages - some output could not be parsed`,
				{ kind: 'parse' },
			);
		}
	};

	return { [Symbol.asyncIterator]: iterate };
};

export const ocrDocument = Object.assign(ocrDocumentSingle, {
	/** Recognize every page of a PDF as a structured document result. */
	pages: ocrDocumentPages,
});
