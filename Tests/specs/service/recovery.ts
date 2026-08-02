import { describe, expect, test } from 'manten';
import { ocr, type MacOcrError } from '../../../src/index.ts';
import {
	pendingServiceRequestsForTesting,
	servicePidForTesting,
} from '../../../src/service/index.ts';
import { fixtureData, importWrapper } from '../../utils.ts';
import {
	ensureServiceForTesting,
	serviceDirectories,
	serviceShim,
	waitFor,
} from './utils.ts';

await describe('recovery', () => {
	test('rejects cleanly when the service binary cannot spawn', async () => {
		await using wrapper = await importWrapper(undefined, { service: true });
		const error = await wrapper.api.ocr(Buffer.from('dummy')).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(wrapper.api.MacOcrError);
		expect((error as MacOcrError).kind).toBe('spawn');
	});

	test('preserves an early service exit code', async () => {
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

	test('preserves exit status after a request write fails', async () => {
		await using wrapper = await importWrapper(`#!/usr/bin/env node
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const directory = path.join(os.tmpdir(), 'mac-ocr-service-' + process.pid + '-' + crypto.randomUUID())
fs.mkdirSync(directory, { mode: 0o700 })
const payload = Buffer.from(JSON.stringify({ type: 'hello', inputDirectory: directory }))
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

	test('rejects pending work and lazily restarts after a crash', async () => {
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
		await waitFor(
			() => servicePidForTesting() === undefined,
			'mac-ocr service did not stop',
		);
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

	test('restarts after losing the service input directory', async () => {
		await using wrapper = await importWrapper(serviceShim({
			setup: `const marker = path.join(__dirname, '.started')
const firstStart = !fs.existsSync(marker)
fs.writeFileSync(marker, '')`,
			afterHello: 'if (firstStart) fs.rmSync(directory, { recursive: true, force: true })',
			onRequest: `if (request.command === 'ocr') {
  frame({
    id: request.id,
    type: 'result',
    result: { page: 1, pageCount: 1, width: 1, height: 1, text: 'recovered', observations: [] },
  })
}`,
		}), { service: true });
		const first = await wrapper.api.ocr(Buffer.from('first')).catch((error: unknown) => error);
		expect(first).toMatchObject({ kind: 'runtime' });
		const second = await wrapper.api.ocr(Buffer.from('second'));
		expect(second).toMatchObject({ text: 'recovered' });
	});

	test('restarts after losing the service input directory during a request', async () => {
		await using wrapper = await importWrapper(serviceShim({
			setup: `const marker = path.join(__dirname, '.started')
const replacement = fs.existsSync(marker)
fs.writeFileSync(marker, '')`,
			onRequest: `if (replacement) {
  frame({
    id: request.id,
    type: 'result',
    result: { page: 1, pageCount: 1, width: 1, height: 1, text: 'recovered', observations: [] },
  })
} else {
  fs.rmSync(directory, { recursive: true, force: true })
  frame({
    id: request.id,
    type: 'error',
    error: { kind: 'runtime', message: 'directory lost', exitCode: 1, stderr: '' },
  })
}`,
		}), { service: true });
		const first = await wrapper.api.ocr(Buffer.from('first')).catch((error: unknown) => error);
		expect(first).toMatchObject({ kind: 'runtime' });
		const second = await wrapper.api.ocr(Buffer.from('second'));
		expect(second).toMatchObject({ text: 'recovered' });
	});
}, { parallel: false });
