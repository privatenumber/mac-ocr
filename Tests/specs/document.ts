import childProcess from 'node:child_process';
import { describe, expect, test } from 'manten';
import { MacOcrError, ocrDocument } from '../../src/index.ts';
import { fixtureData } from '../utils.ts';

const documentRecognitionAvailable = Number(
	childProcess.execFileSync('sw_vers', ['-productVersion'], { encoding: 'utf8' }).split('.')[0],
) >= 26;

await describe('ocrDocument', () => {
	test('returns structured content for an image', async () => {
		if (!documentRecognitionAvailable) {
			const error = await ocrDocument(fixtureData('hello.png')).catch((error_: unknown) => error_);
			expect(error).toBeInstanceOf(MacOcrError);
			expect((error as MacOcrError).kind).toBe('unavailable');
			expect((error as MacOcrError).code).toBe('document_recognition_unavailable');
			return;
		}

		const result = await ocrDocument(fixtureData('hello.png'));
		expect(result.schema).toBe('mac-ocr.document');
		expect(result.schemaVersion).toBe(1);
		expect(result.text).toBe('Hello World');
		expect(result.documents).toHaveLength(1);
		expect(result.documents[0]?.content.text.lines[0]?.transcript).toBe('Hello World');
	});

	test('streams document results for PDF pages', async () => {
		if (!documentRecognitionAvailable) {
			let error: unknown;
			try {
				// eslint-disable-next-line no-empty -- draining is the unavailable-path scenario
				for await (const _page of ocrDocument.pages(fixtureData('multipage.pdf'))) {}
			} catch (error_) {
				error = error_;
			}
			expect(error).toBeInstanceOf(MacOcrError);
			expect((error as MacOcrError).kind).toBe('unavailable');
			return;
		}

		const pages = await Array.fromAsync(ocrDocument.pages(fixtureData('multipage.pdf')));
		expect(pages).toHaveLength(3);
		expect(pages.map(page => page.page)).toStrictEqual([1, 2, 3]);
		expect(pages.every(page => page.pageCount === 3)).toBe(true);
	});

	test('rejects a multi-page PDF from the single-result API', async () => {
		const error = await ocrDocument(fixtureData('multipage.pdf')).catch((error_: unknown) => error_);
		if (!documentRecognitionAvailable) {
			expect(error).toMatchObject({ kind: 'unavailable' });
			return;
		}
		expect(error).toMatchObject({ kind: 'usage' });
	});
}, { parallel: false });
