import { describe, test, expect } from 'manten';
import { ocr } from '../../src/index.ts';
import { fixtureData } from '../utils.ts';

await describe('ocr.pages', () => {
	test('streams each page in order', async () => {
		const pages = [];
		for await (const page of ocr.pages(fixtureData('multipage.pdf'))) {
			pages.push(page);
		}
		expect(pages.map(page => page.page)).toEqual([1, 2, 3]);
		expect(pages.every(page => page.pageCount === 3)).toBe(true);
		expect(pages[0].text).toContain('Page One');
		expect(pages[1].text).toContain('Page Two');
		expect(pages[2].text).toContain('Page Three');
	});

	test('Array.fromAsync collects every page into an array', async () => {
		const pages = await Array.fromAsync(ocr.pages(fixtureData('multipage.pdf')));
		expect(pages).toHaveLength(3);
		expect(pages.map(page => page.text.split('\n')[0])).toEqual(['Page One', 'Page Two', 'Page Three']);
	});

	test('works on a single image (one page)', async () => {
		const pages = await Array.fromAsync(ocr.pages(fixtureData('hello.png')));
		expect(pages).toHaveLength(1);
		expect(pages[0].text).toContain('Hello World');
	});

	test('can break out of the stream early', async () => {
		let seen = 0;
		// eslint-disable-next-line no-unreachable-loop -- break-early is the scenario under test
		for await (const _page of ocr.pages(fixtureData('multipage.pdf'))) {
			seen += 1;
			break;
		}
		expect(seen).toBe(1);
	});

	test('rejects re-consuming the same result', async () => {
		const pages = ocr.pages(fixtureData('multipage.pdf'));
		await Array.fromAsync(pages); // consume once
		await expect(Array.fromAsync(pages)).rejects.toThrow(/already consumed/);
	});

	test('is not awaitable directly (plain AsyncIterable)', () => {
		const pages = ocr.pages(fixtureData('multipage.pdf'));
		expect('then' in pages).toBe(false);
		// Never iterated — no subprocess was spawned (lazy), nothing to clean up.
	});
}, { parallel: false });
