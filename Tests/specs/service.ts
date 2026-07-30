import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { Worker } from 'node:worker_threads';
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

	await test('rejects malformed protocol frames instead of crashing', async () => {
		await using wrapper = await importWrapper(`#!/usr/bin/env node
const payload = Buffer.from('null')
const header = Buffer.alloc(4)
header.writeUInt32LE(payload.length)
process.stdout.write(Buffer.concat([header, payload]))
setTimeout(() => {}, 30_000)
`, { service: true });
		const error = await wrapper.api.ocr(Buffer.from('x')).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(wrapper.api.MacOcrError);
		expect(error).toMatchObject({ kind: 'runtime' });
	});

	await test('keeps stderr scoped to its structured response', async () => {
		await using wrapper = await importWrapper(String.raw`#!/usr/bin/env node
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const directory = path.join(os.tmpdir(), 'mac-ocr-service-' + process.pid + '-' + crypto.randomUUID())
fs.mkdirSync(directory, { mode: 0o700 })
const frame = value => {
  const payload = Buffer.from(JSON.stringify(value))
  const header = Buffer.alloc(4)
  header.writeUInt32LE(payload.length)
  process.stdout.write(Buffer.concat([header, payload]))
}
frame({ type: 'hello', protocolVersion: 1, binaryVersion: 'test', inputDirectory: directory })
let buffered = Buffer.alloc(0)
process.stdin.on('data', chunk => {
  buffered = Buffer.concat([buffered, chunk])
  const length = buffered.readUInt32LE(0)
  if (buffered.length < length + 4) return
  const request = JSON.parse(buffered.subarray(4, length + 4))
  process.stderr.write('diagnostic from another request\n')
  frame({
    id: request.id,
    type: 'error',
    error: { kind: 'usage', message: 'request failed', exitCode: null, stderr: '' },
  })
})
`, { service: true });
		try {
			const error = await wrapper.api.ocr(Buffer.from('x')).catch((error_: unknown) => error_);
			expect(error).toMatchObject({ stderr: '' });
		} finally {
			wrapper.serviceApi.stopService();
		}
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
		const pid = servicePidForTesting();
		const result = await ocr(fixtureData('hello.png'), { password: '\uD800' });
		expect(result.text).toContain('Hello World');
		expect(servicePidForTesting()).toBe(pid);
	});

	await test('rejects a pre-aborted service request', async () => {
		const pid = servicePidForTesting();
		const controller = new AbortController();
		controller.abort();
		const error = await ocr(
			fixtureData('hello.png'),
			{ signal: controller.signal },
		).catch((error_: unknown) => error_);
		expect(error).toMatchObject({ kind: 'abort' });
		expect(servicePidForTesting()).toBe(pid);
	});

	await test('removes an aborted queued request before staging', async () => {
		const pid = servicePidForTesting();
		const blocker = ocr(fixtureData('document-photo.png'));
		await waitFor(
			() => pendingServiceRequestsForTesting() > 0,
			'Expected the blocking service request to start',
		);
		const controller = new AbortController();
		const queued = ocr(fixtureData('hello.png'), { signal: controller.signal });
		controller.abort();
		const outcome = await Promise.race([
			queued.catch((error: unknown) => error),
			delay(250, 'timeout'),
		]);
		expect(outcome).toMatchObject({ kind: 'abort' });
		await blocker;
		expect(servicePidForTesting()).toBe(pid);
	});

	await test('cancels active Vision work without stopping the service', async () => {
		const pid = servicePidForTesting();
		const controller = new AbortController();
		const pending = ocr(
			fixtureData('document-photo.png'),
			{ signal: controller.signal },
		);
		await waitFor(
			() => pendingServiceRequestsForTesting() > 0,
			'Expected the cancellable service request to start',
		);
		controller.abort();
		const error = await pending.catch((error_: unknown) => error_);
		expect(error).toMatchObject({ kind: 'abort' });
		const result = await ocr(fixtureData('hello.png'));
		expect(result.text).toContain('Hello World');
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
		await waitFor(
			async () => {
				const directories = await serviceDirectories();
				return !directories.some(
					name => name.startsWith(`mac-ocr-service-${pid}-`),
				);
			},
			'Expected the crashed service directory to be removed',
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

	await test('keeps worker-thread calls on the one-shot path', async () => {
		const indexUrl = pathToFileURL(new URL('../../src/index.ts', import.meta.url).pathname).href;
		const serviceUrl = pathToFileURL(new URL('../../src/service.ts', import.meta.url).pathname).href;
		const fixtureUrl = pathToFileURL(new URL('../fixtures/hello.png', import.meta.url).pathname).href;
		const source = `
import fs from 'node:fs/promises'
import { parentPort } from 'node:worker_threads'
import { ocr } from ${JSON.stringify(indexUrl)}
import { servicePidForTesting } from ${JSON.stringify(serviceUrl)}
const result = await ocr(await fs.readFile(new URL(${JSON.stringify(fixtureUrl)})))
parentPort.postMessage([result.text.includes('Hello World'), servicePidForTesting() ?? null])
`;
		const worker = new Worker(new URL(`data:text/javascript,${encodeURIComponent(source)}`));
		const message = once(worker, 'message');
		const exit = once(worker, 'exit');
		try {
			expect(await message).toStrictEqual([[true, null]]);
			expect(await exit).toStrictEqual([0]);
		} finally {
			await worker.terminate();
		}
	});
});
