import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { describe, expect, test } from 'manten';
import { ocr } from '../../src/index.ts';
import {
	pendingServiceRequestsForTesting,
	servicePidForTesting,
	stopService,
} from '../../src/service.ts';
import { fixtureData, importWrapper } from '../utils.ts';

const pgrep = (pattern: string): Promise<string> => new Promise((resolve) => {
	const check = spawn('pgrep', ['-f', pattern]);
	let found = '';
	check.stdout.on('data', (chunk) => {
		found += chunk;
	});
	check.on('close', () => resolve(found.trim()));
});

const serviceDirectories = async (): Promise<string[]> => {
	const names = await fs.readdir(os.tmpdir());
	return names.filter(name => /^mac-ocr-service-\d+-[0-9A-Fa-f-]{36}$/.test(name));
};

const processExists = (pid: number): boolean => {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
};

const waitForServiceStop = async (): Promise<void> => {
	const deadline = Date.now() + 2000;
	while (servicePidForTesting() !== undefined && Date.now() < deadline) {
		await delay(20);
	}
	if (servicePidForTesting() !== undefined) {
		throw new Error('mac-ocr service did not stop');
	}
};

const waitFor = async (
	condition: () => boolean | Promise<boolean>,
	message: string,
): Promise<void> => {
	const deadline = Date.now() + 2000;
	while (!await condition() && Date.now() < deadline) {
		await delay(20);
	}
	if (!await condition()) {
		throw new Error(message);
	}
};

await describe('ocr service', async () => {
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
		const pid = servicePidForTesting();
		const results = await Promise.all(Array.from(
			{ length: 8 },
			() => ocr(fixtureData('hello.png')),
		));
		expect(results.every(result => result.text.includes('Hello World'))).toBe(true);
		expect(servicePidForTesting()).toBe(pid);
	});

	await test('preserves runtime errors and keeps the service alive', async () => {
		const pid = servicePidForTesting();
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
		const pid = servicePidForTesting();
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
		try {
			const result = await ocr(fixtureData('encrypted.pdf'));
			expect(result.text).toContain('Hello World');
		} finally {
			if (previous === undefined) {
				delete process.env.MAC_OCR_PDF_PASSWORD;
			} else {
				process.env.MAC_OCR_PDF_PASSWORD = previous;
			}
		}
	});

	await test('keeps AbortSignal calls on the one-shot path', async () => {
		const pid = servicePidForTesting();
		const controller = new AbortController();
		controller.abort();
		await expect(ocr(fixtureData('hello.png'), { signal: controller.signal })).rejects.toThrow(/abort/i);
		expect(servicePidForTesting()).toBe(pid);
	});

	await test('rejects pending work and lazily restarts after a crash', async () => {
		const pid = servicePidForTesting();
		if (!pid) {
			throw new Error('Expected a running service');
		}
		const pending = Array.from(
			{ length: 8 },
			() => ocr(fixtureData('hello.png')),
		);
		await waitFor(
			() => pendingServiceRequestsForTesting() > 0,
			'Expected pending service requests before the crash',
		);
		process.kill(pid, 'SIGKILL');
		const outcomes = await Promise.allSettled(pending);
		expect(outcomes.some(outcome => outcome.status === 'rejected')).toBe(true);
		await waitForServiceStop();
		const result = await ocr(fixtureData('hello.png'));
		expect(result.text).toContain('Hello World');
		expect(servicePidForTesting()).not.toBe(pid);
		const currentPid = servicePidForTesting();
		await waitFor(
			async () => {
				const directories = await serviceDirectories();
				return directories.every(
					name => name.startsWith(`mac-ocr-service-${currentPid}-`),
				);
			},
			'Expected stale service directories to be removed',
		);
	});

	await test('can stop and lazily restart the internal singleton', async () => {
		const pid = servicePidForTesting();
		stopService();
		await waitForServiceStop();
		const result = await ocr(fixtureData('hello.png'));
		expect(result.text).toContain('Hello World');
		expect(servicePidForTesting()).not.toBe(pid);
	});

	await test('can stop a service that is still starting', async () => {
		await using wrapper = await importWrapper(
			'#!/usr/bin/env node\nsetTimeout(() => {}, 30_000)\n',
			{ service: true },
		);
		const pending = wrapper.api.ocr(Buffer.from('x')).catch((error: unknown) => error);
		await waitFor(
			() => wrapper.serviceApi.startingServicePidForTesting() !== undefined,
			'Expected the service process to start before stopService()',
		);
		wrapper.serviceApi.stopService();
		expect(await pending).toBeInstanceOf(wrapper.api.MacOcrError);
		const deadline = Date.now() + 2000;
		let leftover = await pgrep(wrapper.binaryPath);
		while (leftover && Date.now() < deadline) {
			await delay(20);
			leftover = await pgrep(wrapper.binaryPath);
		}
		expect(leftover).toBe('');
	});

	await test('stops and removes staged inputs when its Node parent exits', async () => {
		const indexUrl = pathToFileURL(new URL('../../src/index.ts', import.meta.url).pathname).href;
		const serviceUrl = pathToFileURL(new URL('../../src/service.ts', import.meta.url).pathname).href;
		const fixtureUrl = pathToFileURL(new URL('../fixtures/hello.png', import.meta.url).pathname).href;
		const script = `
import fs from 'node:fs/promises'
import { ocr } from ${JSON.stringify(indexUrl)}
import { servicePidForTesting } from ${JSON.stringify(serviceUrl)}
void ocr(await fs.readFile(new URL(${JSON.stringify(fixtureUrl)})))
while (servicePidForTesting() === undefined) await new Promise(resolve => setTimeout(resolve, 10))
process.stdout.write(String(servicePidForTesting()))
process.exit(0)
`;
		const parent = spawn(process.execPath, ['--input-type=module', '--eval', script]);
		let stdout = '';
		let stderr = '';
		parent.stdout.on('data', (chunk) => {
			stdout += chunk;
		});
		parent.stderr.on('data', (chunk) => {
			stderr += chunk;
		});
		await new Promise<void>((resolve, reject) => {
			parent.once('error', reject);
			parent.once('close', (code) => {
				if (code === 0) {
					resolve();
				} else {
					reject(new Error(`Helper exited ${code}: ${stderr}`));
				}
			});
		});
		const servicePid = Number(stdout);
		expect(servicePid).toBeGreaterThan(0);
		await waitFor(
			() => !processExists(servicePid),
			'Expected the orphaned service process to stop',
		);
		await waitFor(
			async () => {
				const directories = await serviceDirectories();
				return !directories.some(name => name.startsWith(`mac-ocr-service-${servicePid}-`));
			},
			'Expected the orphaned service directory to be removed',
		);
	});
});
