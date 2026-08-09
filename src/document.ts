import { buildArgs } from './args.ts';
import { parseDocumentLine } from './document-parser.ts';
import { createPageAnalysis } from './page-analysis.ts';
import { spawnBinary } from './process.ts';
import type { Input, OcrDocumentOptions, OcrDocumentResult } from './types.ts';

const documentAnalysis = createPageAnalysis<OcrDocumentResult, OcrDocumentOptions>({
	label: 'mac-ocr document',
	multiPageMessage: 'Input has multiple pages. Use `ocrDocument.pages()` to read them all.',
	pageReuseMessage: 'This ocrDocument.pages() result was already consumed. Call ocrDocument.pages() again to re-read it.',
	missingPageMessage: (yielded, expected) => `mac-ocr document produced ${yielded} of ${expected} pages - some output could not be parsed`,
	spawn: (input, options) => spawnBinary(
		['document', '--format', 'jsonl', ...buildArgs(options), '-'],
		{
			input,
			signal: options?.signal,
			password: options?.password,
		},
	),
	parseLine: parseDocumentLine,
});

export type OcrDocumentPages = AsyncIterable<OcrDocumentResult>;

/** Recognize structured content in image or single-page PDF bytes. */
export const ocrDocument = Object.assign(
	(input: Input, options?: OcrDocumentOptions): Promise<OcrDocumentResult> => documentAnalysis.singleProcess(input, options),
	{
		/** Recognize every page of a PDF as a structured document result. */
		pages: (input: Input, options?: OcrDocumentOptions): OcrDocumentPages => documentAnalysis.pages(input, options),
	},
);
