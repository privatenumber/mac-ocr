import { describe, test, expect } from 'manten';
import { createFixture } from 'fs-fixture';
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

	test('writes a local file atomically to a literal path and preserves input', async () => {
		const original = fixtureData('hello.png');
		await using fixture = await createFixture({ '--scan [image].png': original });
		const input = fixture.getPath('--scan [image].png');
		const output = fixture.getPath('nested/[name] output.pdf');
		expect(await createSearchablePdf({
			inputPath: input,
			outputPath: output,
			ocrStrategy: 'standard',
		})).toBeUndefined();
		expect(pdfHeader(await fixture.readFile('nested/[name] output.pdf'))).toBe('%PDF-');
		expect(await fixture.readFile('--scan [image].png')).toStrictEqual(original);
		await fixture.writeFile('nested/[name] output.pdf', 'previous output');
		await fixture.writeFile('invalid.png', 'invalid');
		await expect(createSearchablePdf({
			inputPath: fixture.getPath('invalid.png'),
			outputPath: output,
		})).rejects.toMatchObject({ kind: 'runtime' });
		expect(await fixture.readFile('nested/[name] output.pdf', 'utf8')).toBe('previous output');
		expect(await fixture.readdir('nested')).toStrictEqual(['[name] output.pdf']);
	});
}, { parallel: false });
