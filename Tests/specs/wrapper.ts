import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { text } from 'node:stream/consumers';
import { setTimeout } from 'node:timers/promises';
import { describe, test, expect } from 'manten';
import { buildArgs } from '../../src/args.ts';
import type { MacOcrError } from '../../src/index.ts';
import { importWrapper } from '../utils.ts';

/**
 * These specs pin wrapper logic (arg/env construction, stream parsing, exit
 * classification) against scripted shim binaries instead of the real CLI —
 * `importWrapper` plants any executable at the wrapper's `bin/mac-ocr`
 * location, so a tiny `/bin/sh` script can emit exactly the stdout/exit
 * behavior under test, with no Vision involved.
 */

const shShim = (script: string): string => `#!/bin/sh\n${script}\n`;

const jsonlLine = (page: number, pageCount: number, content: string): string => JSON.stringify({
	page,
	pageCount,
	width: 1,
	height: 1,
	text: content,
	observations: [],
});

/**
 * A Node shim that emits one page announcing more, then stalls — the wrapper
 * must kill it. Node (not `sh`) so the process holds its unique script path
 * in its argv for `pgrep -f`.
 */
const stallingShim = '#!/usr/bin/env node\n'
	+ `console.log(${JSON.stringify(jsonlLine(1, 3, 'one'))});\n`
	+ 'setTimeout(() => {}, 30_000);\n';

const pgrep = async (pattern: string): Promise<string> => {
	const check = spawn('pgrep', ['-f', pattern]);
	const output = text(check.stdout);
	await once(check, 'close');
	const result = await output;
	return result.trim();
};

/**
 * Assert the shim process is gone. The wrapper dispatches the kill before the
 * call returns, but process death isn't synchronous, so poll briefly instead
 * of flaking on reap timing.
 */
const expectNoLingeringShim = async (marker: string): Promise<void> => {
	const deadline = Date.now() + 2000;
	let leftover = await pgrep(marker);
	while (leftover && Date.now() < deadline) {
		await setTimeout(50);
		leftover = await pgrep(marker);
	}
	expect(leftover).toBe('');
};

describe('wrapper (shim binary)', () => {
	test('buildArgs never emits --password', () => {
		const args = buildArgs({
			password: 'hunter2',
			fast: true,
		});
		expect(args).not.toContain('--password');
		expect(args).not.toContain('hunter2');
	});

	test('password reaches the CLI via env, not argv', async () => {
		// The shim reports its env + argv back through the result text.
		await using wrapper = await importWrapper(shShim(
			String.raw`printf '{"page":1,"pageCount":1,"width":1,"height":1,"text":"pw=%s argv=%s","observations":[]}\n' "$MAC_OCR_PDF_PASSWORD" "$*"`,
		));
		const result = await wrapper.api.ocr(Buffer.from('x'), { password: 'hunter2' });
		expect(result.text).toContain('pw=hunter2');
		expect(result.text).not.toContain('--password');
	});

	test('createSearchablePdf forwards imageQuality', async () => {
		await using wrapper = await importWrapper(shShim(String.raw`printf '%%PDF- argv=%s' "$*"`));
		const pdf = await wrapper.api.createSearchablePdf(Buffer.from('x'), { imageQuality: 0.75 });
		expect(Buffer.from(pdf).toString()).toContain('--image-quality 0.75');
	});

	test('createSearchablePdf forwards imagePageDpi', async () => {
		await using wrapper = await importWrapper(shShim(String.raw`printf '%%PDF- argv=%s' "$*"`));
		const pdf = await wrapper.api.createSearchablePdf(Buffer.from('x'), { imagePageDpi: 300 });
		expect(Buffer.from(pdf).toString()).toContain('--image-page-dpi 300');
	});

	test('createSearchablePdf forwards imageDownsampleDpi', async () => {
		await using wrapper = await importWrapper(shShim(String.raw`printf '%%PDF- argv=%s' "$*"`));
		const pdf = await wrapper.api.createSearchablePdf(Buffer.from('x'), { imageDownsampleDpi: 200 });
		expect(Buffer.from(pdf).toString()).toContain('--image-downsample-dpi 200');
	});

	test('createSearchablePdf forwards ocrStrategy', async () => {
		await using wrapper = await importWrapper(shShim(String.raw`printf '%%PDF- argv=%s' "$*"`));
		const pdf = await wrapper.api.createSearchablePdf(Buffer.from('x'), { ocrStrategy: 'standard' });
		expect(Buffer.from(pdf).toString()).toContain('--ocr-strategy standard');
	});

	test('ocr() fails multi-page input from the first page, without waiting', async () => {
		// Page 1 announces pageCount 3; the shim then stalls. The wrapper must
		// reject from pageCount alone instead of waiting for page 2. (`exec`
		// replaces the shell so the wrapper's kill signal reaches the sleeper
		// directly — a forked `sleep` would orphan-hold the stdout pipe.)
		await using wrapper = await importWrapper(shShim([
			String.raw`printf '%s\n' '${jsonlLine(1, 3, 'one')}'`,
			'exec sleep 5',
		].join('\n')));
		const start = Date.now();
		const error = await wrapper.api.ocr(Buffer.from('x')).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(wrapper.api.MacOcrError);
		expect((error as MacOcrError).kind).toBe('usage');
		// Old behavior waited for page 2 (5s); fast-fail returns immediately.
		expect(Date.now() - start).toBeLessThan(4000);
	});

	test('ocr.pages() errors when pages are lost to unparseable lines', async () => {
		await using wrapper = await importWrapper(shShim([
			String.raw`printf '%s\n' '${jsonlLine(1, 3, 'one')}'`,
			String.raw`printf 'GARBAGE\n'`,
			String.raw`printf '%s\n' '${jsonlLine(2, 3, 'two')}'`,
		].join('\n')));
		const seen: number[] = [];
		let error: unknown;
		try {
			for await (const page of wrapper.api.ocr.pages(Buffer.from('x'))) {
				seen.push(page.page);
			}
		} catch (error_) {
			error = error_;
		}
		expect(error).toBeInstanceOf(wrapper.api.MacOcrError);
		expect((error as MacOcrError).kind).toBe('parse');
		expect((error as MacOcrError).message).toMatch(/2 of 3 pages/);
		expect(seen).toEqual([1, 2]);
	});

	test('ocr.pages() errors on a clean exit with no output', async () => {
		await using wrapper = await importWrapper(shShim('exit 0'));
		let error: unknown;
		try {
			// eslint-disable-next-line no-empty -- draining is the scenario
			for await (const _page of wrapper.api.ocr.pages(Buffer.from('x'))) {}
		} catch (error_) {
			error = error_;
		}
		expect(error).toBeInstanceOf(wrapper.api.MacOcrError);
		expect((error as MacOcrError).kind).toBe('parse');
		expect((error as MacOcrError).message).toMatch(/produced no output/);
	});

	test('an externally killed binary is a runtime error, not an abort', async () => {
		await using wrapper = await importWrapper(shShim('kill -KILL $$'));
		const error = await wrapper.api.ocr(Buffer.from('x')).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(wrapper.api.MacOcrError);
		expect((error as MacOcrError).kind).toBe('runtime');
		expect((error as MacOcrError).message).toContain('SIGKILL');
	});

	test('aborting ocr.pages() kills the subprocess — no zombie', async () => {
		await using wrapper = await importWrapper(stallingShim);
		const controller = new AbortController();
		const seen: number[] = [];
		let error: unknown;
		try {
			for await (const page of wrapper.api.ocr.pages(Buffer.from('x'), { signal: controller.signal })) {
				seen.push(page.page);
				controller.abort();
			}
		} catch (error_) {
			error = error_;
		}
		expect(error).toBeInstanceOf(wrapper.api.MacOcrError);
		expect((error as MacOcrError).kind).toBe('abort');
		expect(seen).toEqual([1]);
		await expectNoLingeringShim(wrapper.binaryPath);
	});

	test('breaking out of ocr.pages() kills the subprocess — no zombie', async () => {
		await using wrapper = await importWrapper(stallingShim);
		let seen = 0;
		// eslint-disable-next-line no-unreachable-loop -- break-early is the scenario under test
		for await (const _page of wrapper.api.ocr.pages(Buffer.from('x'))) {
			seen += 1;
			break;
		}
		expect(seen).toBe(1);
		await expectNoLingeringShim(wrapper.binaryPath);
	});
});
