import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, test } from 'manten';
import { ocr } from '../../../src/index.ts';
import {
	pendingServiceRequestsForTesting,
	servicePidForTesting,
	stopService,
} from '../../../src/service/index.ts';
import { fixtureData } from '../../utils.ts';
import {
	ensureServiceForTesting,
	serviceDirectories,
	waitFor,
} from './utils.ts';

await describe('requests', async () => {
	await test('reuses one hidden process across calls', async () => {
		stopService();
		const first = await ocr(fixtureData('hello.png'));
		const firstPid = servicePidForTesting();
		const second = await ocr(fixtureData('hello.png'));
		expect(first.text).toContain('Hello World');
		expect(second.text).toContain('Hello World');
		expect(firstPid).toBeGreaterThan(0);
		expect(servicePidForTesting()).toBe(firstPid);
	});

	await test('serializes concurrent calls through the same service', async () => {
		const pid = await ensureServiceForTesting();
		const pending = Array.from(
			{ length: 8 },
			() => ocr(fixtureData('hello.png')),
		);
		await waitFor(
			() => pendingServiceRequestsForTesting() > 0,
			'Expected a pending service request',
		);
		const directories = await serviceDirectories();
		const directory = directories.find(
			name => name.startsWith(`mac-ocr-service-${pid}-`),
		);
		if (!directory) {
			throw new Error('Expected a service input directory');
		}
		const stagedInputs = await fs.readdir(path.join(os.tmpdir(), directory));
		expect(stagedInputs.length).toBeLessThanOrEqual(1);
		const results = await Promise.all(pending);
		expect(results.every(result => result.text.includes('Hello World'))).toBe(true);
		expect(servicePidForTesting()).toBe(pid);
	});

	await test('preserves runtime errors and keeps the service alive', async () => {
		const pid = await ensureServiceForTesting();
		const error = await ocr(Buffer.from('not an image')).catch((error_: unknown) => error_);
		expect(error).toMatchObject({
			kind: 'runtime',
			code: 'batch_failed',
			exitCode: 1,
		});
		expect((error as Error).message).toMatch(/^Cannot read image/);
		expect(servicePidForTesting()).toBe(pid);
		const result = await ocr(fixtureData('hello.png'));
		expect(result.text).toContain('Hello World');
	});

	await test('preserves the wrapper-synthesized multi-page usage error', async () => {
		const pid = await ensureServiceForTesting();
		const error = await ocr(fixtureData('multipage.pdf')).catch((error_: unknown) => error_);
		expect(error).toMatchObject({
			kind: 'usage',
			exitCode: null,
		});
		expect((error as Error).message).toMatch(/ocr\.pages/);
		expect(servicePidForTesting()).toBe(pid);
	});

	await test('reads the ambient PDF password for each request', async () => {
		const previous = process.env.MAC_OCR_PDF_PASSWORD;
		process.env.MAC_OCR_PDF_PASSWORD = 'secret';
		const resultPromise = ocr(fixtureData('encrypted.pdf'));
		if (previous === undefined) {
			delete process.env.MAC_OCR_PDF_PASSWORD;
		} else {
			process.env.MAC_OCR_PDF_PASSWORD = previous;
		}
		const result = await resultPromise;
		expect(result.text).toContain('Hello World');
	});

	await test('snapshots mutable options before queueing', async () => {
		const options = { languages: ['en-US'] };
		const resultPromise = ocr(fixtureData('hello.png'), options);
		options.languages = ['klingon'];
		const result = await resultPromise;
		expect(result.text).toContain('Hello World');
	});

	await test('snapshots mutable input bytes before queueing', async () => {
		const input = fixtureData('hello.png');
		const resultPromise = ocr(input);
		input.fill(0);
		const result = await resultPromise;
		expect(result.text).toContain('Hello World');
	});

	await test('normalizes protocol strings to well-formed Unicode', async () => {
		const pid = await ensureServiceForTesting();
		const result = await ocr(fixtureData('hello.png'), { password: '\uD800' });
		expect(result.text).toContain('Hello World');
		expect(servicePidForTesting()).toBe(pid);
	});
});
