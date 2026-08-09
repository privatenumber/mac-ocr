import { createInterface } from 'node:readline';
import { buildArgs } from './args.ts';
import { parseDocumentLine } from './document-parser.ts';
import { MacOcrError } from './errors.ts';
import { spawnBinary, waitForExit, type Spawned } from './process.ts';
import type { Input, OcrDocumentOptions, OcrDocumentResult } from './types.ts';

const label = 'mac-ocr document';

const spawnDocument = (input: Input, options?: OcrDocumentOptions): Spawned => spawnBinary(
	['document', '--format', 'jsonl', ...buildArgs(options), '-'],
	{
		input,
		signal: options?.signal,
		password: options?.password,
	},
);

export type OcrDocumentPages = AsyncIterable<OcrDocumentResult>;

/** Recognize structured content in image or single-page PDF bytes. */
const ocrDocumentSingle = async (
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
	if (!isValidPage(first)) {
		throw new MacOcrError(`${label} produced invalid page metadata`, { kind: 'parse' });
	}
	return first;
};

const isValidPage = (page: OcrDocumentResult, expectedPageCount?: number): boolean => (
	Number.isSafeInteger(page.page)
	&& Number.isSafeInteger(page.pageCount)
	&& page.page >= 1
	&& page.pageCount >= 1
	&& page.page <= page.pageCount
	&& (expectedPageCount === undefined || page.pageCount === expectedPageCount)
);

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

		const spawned = spawnDocument(input, options);
		let completed = false;
		let yielded = 0;
		let expectedPageCount: number | undefined;
		const seenPages = new Set<number>();
		let invalidPageMetadata = false;
		try {
			for await (const line of createInterface({ input: spawned.proc.stdout })) {
				const page = parseDocumentLine(line);
				if (page !== undefined) {
					if (!isValidPage(page, expectedPageCount)) {
						invalidPageMetadata = true;
						continue;
					}
					expectedPageCount = page.pageCount;
					seenPages.add(page.page);
					yielded += 1;
					yield page;
				}
			}
			completed = true;
		} finally {
			// A consumer break or parse failure must stop the one-shot child before
			// yielding control; only a fully drained stream can surface its exit.
			if (completed) {
				await waitForExit(spawned, label);
			} else {
				spawned.proc.kill();
				await spawned.exit.catch(() => {});
			}
		}

		if (expectedPageCount === undefined) {
			throw new MacOcrError(`${label} produced no output`, { kind: 'parse' });
		}
		if (
			invalidPageMetadata
			|| seenPages.size !== expectedPageCount
			|| yielded !== expectedPageCount
		) {
			throw new MacOcrError(
				`${label} produced ${yielded} of ${expectedPageCount} pages - some output could not be parsed`,
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
