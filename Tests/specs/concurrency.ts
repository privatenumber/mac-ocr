import { describe, test, expect } from 'manten';
import { ocr, createSearchablePdf } from '../../src/index.ts';
import { fixtureData } from '../utils.ts';

/**
 * A realistic mixed `Promise.all` burst: ordinary OCR calls share the serial
 * native service, while page streaming and searchable-PDF retain dedicated
 * subprocesses. This verifies the service and one-shot paths compose without
 * corrupting results or process lifecycle.
 */
await describe('concurrency', async () => {
	test('a parallel burst of mixed calls all resolve correctly', async () => {
		const hello = fixtureData('hello.png');
		const multipage = fixtureData('multipage.pdf');

		const [pages, pdf, ...singles] = await Promise.all([
			Array.fromAsync(ocr.pages(multipage)),
			createSearchablePdf(hello),
			...Array.from({ length: 6 }, () => ocr(hello)),
		]);

		for (const result of singles) {
			expect(result.text).toContain('Hello World');
		}
		expect(pages.map(page => page.page)).toEqual([1, 2, 3]);
		expect(Buffer.from(pdf.subarray(0, 5)).toString('utf8')).toBe('%PDF-');
	});
});
