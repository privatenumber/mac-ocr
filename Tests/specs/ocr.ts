import { describe, test, expect } from 'manten';
import { ocr, MacOcrError } from '../../src/index.ts';
import { fixtureData } from '../utils.ts';

// Tests are awaited (sequential) so at most one Vision subprocess runs at a
// time — concurrent Vision processes contend for the ANE (the same reason the
// Swift suite runs --no-parallel).
await describe('ocr', async () => {
	await test('recognizes text from bytes', async () => {
		const result = await ocr(fixtureData('hello.png'));
		expect(result.text).toContain('Hello World');
		expect(result.page).toBe(1);
		expect(result.pageCount).toBe(1);
		expect(result.width).toBe(400);
		expect(result.height).toBe(100);
		expect(result.observations.length).toBeGreaterThan(0);
		// The Node API drops the always-"buffer" source field.
		expect('source' in result).toBe(false);
	});

	await test('returns observations with bounding boxes', async () => {
		const { observations } = await ocr(fixtureData('hello.png'));
		const [observation] = observations;
		expect(observation.text).toContain('Hello World');
		expect(observation.confidence).toBeGreaterThan(0);
		for (const key of ['x', 'y', 'width', 'height'] as const) {
			expect(typeof observation.boundingBox[key]).toBe('number');
		}
		// At the default, candidates would just duplicate text/confidence —
		// the field only appears when maxCandidates > 1.
		expect(observation.candidates).toBeUndefined();
	});

	await test('maxCandidates > 1 includes alternative candidates', async () => {
		const { observations } = await ocr(fixtureData('hello.png'), { maxCandidates: 3 });
		const [observation] = observations;
		const candidates = observation.candidates ?? [];
		expect(candidates.length).toBeGreaterThan(0);
		expect(candidates.length).toBeLessThanOrEqual(3);
		expect(candidates[0].text).toBe(observation.text);
	});

	await test('empty image returns no text', async () => {
		const result = await ocr(fixtureData('empty.png'));
		expect(result.text).toBe('');
		expect(result.observations).toHaveLength(0);
	});

	await test('accepts Buffer, Uint8Array, and ArrayBuffer', async () => {
		const buffer = fixtureData('hello.png');
		const uint8 = new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
		const arrayBuffer = buffer.buffer.slice(
			buffer.byteOffset,
			buffer.byteOffset + buffer.byteLength,
		);

		const fromBuffer = await ocr(buffer);
		expect(fromBuffer.text).toContain('Hello World');
		const fromUint8 = await ocr(uint8);
		expect(fromUint8.text).toContain('Hello World');
		const fromArrayBuffer = await ocr(arrayBuffer as ArrayBuffer);
		expect(fromArrayBuffer.text).toContain('Hello World');
	});

	await test('rejects non-bytes input', async () => {
		await expect(ocr('photo.png' as never)).rejects.toThrow(/Buffer, Uint8Array, or ArrayBuffer/);
	});

	await test('fast option', async () => {
		const result = await ocr(fixtureData('hello.png'), { fast: true });
		expect(result.text).toContain('Hello World');
	});

	await test('languages option', async () => {
		const result = await ocr(fixtureData('hello.png'), { languages: ['en-US'] });
		expect(result.text).toContain('Hello World');
	});

	await test('customWords option', async () => {
		const result = await ocr(fixtureData('hello.png'), { customWords: ['Hello'] });
		expect(result.text).toContain('Hello World');
	});

	await test('languageCorrection: false', async () => {
		const result = await ocr(fixtureData('hello.png'), { languageCorrection: false });
		expect(result.text).toContain('Hello World');
	});

	await test('regionOfInterest restricts recognition', async () => {
		const full = await ocr(fixtureData('hello.png'), {
			regionOfInterest: {
				x: 0,
				y: 0,
				width: 1,
				height: 1,
			},
		});
		const topStrip = await ocr(fixtureData('hello.png'), { regionOfInterest: [0, 0, 1, 0.05] });
		expect(full.text).toContain('Hello World');
		expect(topStrip.text).not.toContain('Hello World');
	});

	await test('invalid bytes throw a runtime MacOcrError', async () => {
		const error = await ocr(Buffer.from('not an image')).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(MacOcrError);
		expect((error as MacOcrError).kind).toBe('runtime');
		// The CLI's "Error: " prefix is stripped.
		expect((error as MacOcrError).message).toMatch(/^Cannot read image/);
	});

	await test('multi-page PDF points to ocr.pages()', async () => {
		const error = await ocr(fixtureData('multipage.pdf')).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(MacOcrError);
		expect((error as MacOcrError).kind).toBe('usage');
		expect((error as MacOcrError).message).toMatch(/ocr\.pages/);
	});

	// Covers encrypted-PDF handling through the main-thread API and real binary.
	await test('password unlocks an encrypted PDF', async () => {
		const result = await ocr(fixtureData('encrypted.pdf'), { password: 'secret' });
		expect(result.text).toContain('Hello World');
	});

	await test('encrypted PDF without a password throws a runtime MacOcrError', async () => {
		const error = await ocr(fixtureData('encrypted.pdf')).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(MacOcrError);
		expect((error as MacOcrError).kind).toBe('runtime');
		expect((error as MacOcrError).message).toMatch(/^PDF is password protected/);
	});

	await test('wrong password throws a runtime MacOcrError with the envelope mapped', async () => {
		const error = await ocr(fixtureData('encrypted.pdf'), { password: 'wrong' }).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(MacOcrError);
		const macOcrError = error as MacOcrError;
		expect(macOcrError.kind).toBe('runtime');
		expect(macOcrError.message).toMatch(/^Incorrect password/);
		// Pin the full envelope→MacOcrError mapping once, end to end. The OCR
		// command reports per-input failures through its batch envelope
		// (RootCommand.swift), while the specific message comes from stderr.
		expect(macOcrError.code).toBe('batch_failed');
		expect(macOcrError.exitCode).toBe(1);
		expect(macOcrError.stderr).toContain('Incorrect password');
	});
});
