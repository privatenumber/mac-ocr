import { describe, test, expect } from 'manten';
import { createSearchablePdf, MacOcrError } from '../../src/index.ts';
import { fixtureData } from '../utils.ts';

const pdfHeader = (bytes: Uint8Array): string => Buffer.from(bytes.subarray(0, 5)).toString('utf8');

await describe('createSearchablePdf', () => {
	test('produces a PDF from an image', async () => {
		const pdf = await createSearchablePdf(fixtureData('hello.png'));
		expect(pdf).toBeInstanceOf(Uint8Array);
		expect(pdfHeader(pdf)).toBe('%PDF-');
		expect(pdf.length).toBeGreaterThan(0);
	});

	test('produces a PDF from a multi-page PDF', async () => {
		const pdf = await createSearchablePdf(fixtureData('multipage.pdf'));
		expect(pdfHeader(pdf)).toBe('%PDF-');
	});

	test('forwards options', async () => {
		const pdf = await createSearchablePdf(fixtureData('hello.png'), { fast: true });
		expect(pdfHeader(pdf)).toBe('%PDF-');
	});

	test('forwards ocrAllPages', async () => {
		const pdf = await createSearchablePdf(fixtureData('hello.png'), { ocrAllPages: true });
		expect(pdfHeader(pdf)).toBe('%PDF-');
	});

	test('rejects invalid bytes', async () => {
		const error = await createSearchablePdf(Buffer.from('not an image')).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(MacOcrError);
		expect((error as MacOcrError).kind).toBe('runtime');
	});
}, { parallel: false });
