import fs from 'node:fs/promises';
import { setTimeout } from 'node:timers/promises';
import { describe, test, expect } from 'manten';
import { createFixture } from 'fs-fixture';
import type { MacOcrError } from '../../src/index.ts';
import { importWrapper } from '../utils.ts';

describe('process', () => {
	// A failed spawn (ENOENT) used to crash the host on an uncaught 'error'.
	// Verify it rejects with a typed spawn error instead. The fixture has no
	// bin/mac-ocr at all, so the spawn fails exactly like a broken install.
	test('rejects cleanly when the binary cannot spawn', async () => {
		await using wrapper = await importWrapper();
		const error = await wrapper.api.ocr(Buffer.from('dummy')).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(wrapper.api.MacOcrError);
		expect((error as MacOcrError).kind).toBe('spawn');
	});

	test('file output rejects spawn failures', async () => {
		await using fixture = await createFixture({ 'input.pdf': 'input' });
		await using wrapper = await importWrapper();
		await expect(wrapper.api.createSearchablePdf({
			inputPath: fixture.getPath('input.pdf'),
			outputPath: fixture.getPath('out.pdf'),
		})).rejects.toMatchObject({ kind: 'spawn' });
	});

	test('pre-aborted file output does not start work', async () => {
		await using wrapper = await importWrapper();
		await expect(wrapper.api.createSearchablePdf({
			inputPath: 'absent.pdf',
			outputPath: 'out.pdf',
			signal: AbortSignal.abort(),
		})).rejects.toMatchObject({ kind: 'abort' });
	});

	test('file abort waits for child closure and stops further output work', async () => {
		await using fixture = await createFixture({
			'input.pdf': 'input',
			'out.pdf': 'previous output',
		});
		const ready = fixture.getPath('ready');
		const closed = fixture.getPath('closed');
		await using wrapper = await importWrapper(`#!${process.execPath}
const fs = require('node:fs');
process.on('SIGTERM', () => {
  setTimeout(() => {
    fs.writeFileSync(${JSON.stringify(closed)}, 'closed');
    process.exit(0);
  }, 100);
});
fs.writeFileSync(${JSON.stringify(ready)}, String(process.pid));
setInterval(() => {}, 1000);
`);
		const controller = new AbortController();
		const operation = wrapper.api.createSearchablePdf({
			inputPath: fixture.getPath('input.pdf'),
			outputPath: fixture.getPath('out.pdf'),
			signal: controller.signal,
		}).catch((error_: unknown) => error_);
		try {
			while (!await fixture.exists('ready')) {
				await setTimeout(10);
			}
			controller.abort();
			const error = await operation;
			expect(error).toBeInstanceOf(wrapper.api.MacOcrError);
			expect((error as MacOcrError).kind).toBe('abort');
			expect(await fs.readFile(closed, 'utf8')).toBe('closed');
			expect(await fixture.readFile('out.pdf', 'utf8')).toBe('previous output');
		} finally {
			controller.abort();
			await operation;
		}
	});
});
