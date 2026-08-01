import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { describe, expect, test } from 'manten';
import { ocr, type MacOcrError } from '../../../src/index.ts';
import {
	pendingServiceRequestsForTesting,
	servicePidForTesting,
	stopService,
} from '../../../src/service/index.ts';
import { fixtureData, importWrapper } from '../../utils.ts';
import {
	ensureServiceForTesting,
	serviceDirectories,
	waitFor,
} from './utils.ts';

const pgrep = (pattern: string): Promise<string> => new Promise((resolve) => {
	const check = spawn('pgrep', ['-f', pattern]);
	let found = '';
	check.stdout.on('data', (chunk) => {
		found += chunk;
	});
	check.on('close', () => resolve(found.trim()));
});

const waitForServiceStop = async (): Promise<void> => waitFor(
	() => servicePidForTesting() === undefined,
	'mac-ocr service did not stop',
);

await describe('recovery', async () => {
	await test('rejects cleanly when the service binary cannot spawn', async () => {
		await using wrapper = await importWrapper(undefined, { service: true });
		const error = await wrapper.api.ocr(Buffer.from('dummy')).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(wrapper.api.MacOcrError);
		expect((error as MacOcrError).kind).toBe('spawn');
	});

	await test('preserves an early service exit code', async () => {
		await using wrapper = await importWrapper(
			'#!/usr/bin/env node\nprocess.exit(7)\n',
			{ service: true },
		);
		const error = await wrapper.api.ocr(Buffer.from('dummy')).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(wrapper.api.MacOcrError);
		expect(error).toMatchObject({
			kind: 'runtime',
			exitCode: 7,
		});
		expect((error as Error).message).toMatch(/code 7/);
	});

	await test('preserves exit status after a request write fails', async () => {
		await using wrapper = await importWrapper(`#!/usr/bin/env node
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const directory = path.join(os.tmpdir(), 'mac-ocr-service-' + process.pid + '-' + crypto.randomUUID())
fs.mkdirSync(directory, { mode: 0o700 })
const payload = Buffer.from(JSON.stringify({ type: 'hello', protocolVersion: 1, inputDirectory: directory }))
const header = Buffer.alloc(4)
header.writeUInt32LE(payload.length)
process.stdout.write(Buffer.concat([header, payload]), () => {
  fs.closeSync(0)
  setTimeout(() => process.exit(7), 1000)
})
process.on('exit', () => fs.rmSync(directory, { recursive: true, force: true }))
`, { service: true });
		const error = await wrapper.api.ocr(Buffer.from('dummy')).catch((error_: unknown) => error_);
		expect(error).toMatchObject({
			kind: 'runtime',
			exitCode: 7,
		});
		expect((error as Error).message).toMatch(/code 7/);
	});

	await test('rejects pending work and lazily restarts after a crash', async () => {
		const pid = await ensureServiceForTesting();
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
		const pid = await ensureServiceForTesting();
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
});
