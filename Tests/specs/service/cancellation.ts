import { setTimeout as delay } from 'node:timers/promises';
import fs from 'node:fs/promises';
import { describe, expect, test } from 'manten';
import { ocr } from '../../../src/index.ts';
import {
	pendingServiceRequestsForTesting,
	servicePidForTesting,
} from '../../../src/service/index.ts';
import { fixtureData, importWrapper } from '../../utils.ts';
import { ensureServiceForTesting, waitFor } from './utils.ts';

const processExists = (pid: number): boolean => {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
};

await describe('cancellation', async () => {
	await test('rejects a pre-aborted service request', async () => {
		const pid = await ensureServiceForTesting();
		const controller = new AbortController();
		controller.abort();
		const error = await ocr(
			fixtureData('hello.png'),
			{ signal: controller.signal },
		).catch((error_: unknown) => error_);
		expect(error).toMatchObject({ kind: 'abort' });
		expect(servicePidForTesting()).toBe(pid);
	});

	await test('aborts a stalled startup without blocking the next request', async () => {
		await using wrapper = await importWrapper(`#!/usr/bin/env node
setTimeout(() => {}, 30_000)
`, { service: true });
		try {
			const controller = new AbortController();
			const first = wrapper.api.ocr(
				Buffer.from('first'),
				{ signal: controller.signal },
			).catch((error: unknown) => error);
			await waitFor(
				() => wrapper.serviceApi.startingServicePidForTesting() !== undefined,
				'Expected the stalled service process to start',
			);
			const firstPid = wrapper.serviceApi.startingServicePidForTesting()!;
			await fs.writeFile(wrapper.binaryPath, `#!/usr/bin/env node
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
frame({ type: 'hello', protocolVersion: 1, inputDirectory: directory })
let buffered = Buffer.alloc(0)
process.stdin.on('data', chunk => {
  buffered = Buffer.concat([buffered, chunk])
  while (buffered.length >= 4) {
    const length = buffered.readUInt32LE(0)
    if (buffered.length < length + 4) return
    const request = JSON.parse(buffered.subarray(4, length + 4))
    buffered = buffered.subarray(length + 4)
    if (request.command === 'ocr') {
      frame({
        id: request.id,
        type: 'result',
        result: { page: 1, pageCount: 1, width: 1, height: 1, text: 'ok', observations: [] },
      })
    }
  }
})
process.on('exit', () => fs.rmSync(directory, { recursive: true, force: true }))
`);
			const second = wrapper.api.ocr(Buffer.from('second')).catch((error: unknown) => error);
			controller.abort();
			expect(await first).toMatchObject({ kind: 'abort' });
			await waitFor(
				() => !processExists(firstPid),
				'Expected the aborted startup process to stop',
			);
			const result = await Promise.race([
				second,
				delay(2000, 'timeout'),
			]);
			expect(result).toMatchObject({ text: 'ok' });
		} finally {
			wrapper.serviceApi.stopService();
		}
	});

	await test('removes an aborted queued request before staging', async () => {
		const pid = await ensureServiceForTesting();
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
		const pid = await ensureServiceForTesting();
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

	await test('preserves caller abort when the service exits during cancellation', async () => {
		await using wrapper = await importWrapper(`#!/usr/bin/env node
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
frame({ type: 'hello', protocolVersion: 1, inputDirectory: directory })
let buffered = Buffer.alloc(0)
process.stdin.on('data', chunk => {
  buffered = Buffer.concat([buffered, chunk])
  while (buffered.length >= 4) {
    const length = buffered.readUInt32LE(0)
    if (buffered.length < length + 4) return
    const request = JSON.parse(buffered.subarray(4, length + 4))
    buffered = buffered.subarray(length + 4)
    if (request.command === 'cancel') process.exit(1)
  }
})
`, { service: true });
		const controller = new AbortController();
		const request = wrapper.api.ocr(
			Buffer.from('input'),
			{ signal: controller.signal },
		).catch((error: unknown) => error);
		await waitFor(
			() => wrapper.serviceApi.pendingServiceRequestsForTesting() > 0,
			'Expected the cancellable shim request to start',
		);
		controller.abort();
		expect(await request).toMatchObject({ kind: 'abort' });
	});

	await test('replaces a service that does not acknowledge cancellation', async () => {
		await using wrapper = await importWrapper(`#!/usr/bin/env node
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const marker = path.join(__dirname, '.started')
const replacement = fs.existsSync(marker)
fs.writeFileSync(marker, '')
const directory = path.join(os.tmpdir(), 'mac-ocr-service-' + process.pid + '-' + crypto.randomUUID())
fs.mkdirSync(directory, { mode: 0o700 })
const frame = value => {
  const payload = Buffer.from(JSON.stringify(value))
  const header = Buffer.alloc(4)
  header.writeUInt32LE(payload.length)
  process.stdout.write(Buffer.concat([header, payload]))
}
frame({ type: 'hello', protocolVersion: 1, inputDirectory: directory })
let buffered = Buffer.alloc(0)
process.stdin.on('data', chunk => {
  buffered = Buffer.concat([buffered, chunk])
  while (buffered.length >= 4) {
    const length = buffered.readUInt32LE(0)
    if (buffered.length < length + 4) return
    const request = JSON.parse(buffered.subarray(4, length + 4))
    buffered = buffered.subarray(length + 4)
    if (replacement && request.command === 'ocr') {
      frame({
        id: request.id,
        type: 'result',
        result: { page: 1, pageCount: 1, width: 1, height: 1, text: 'replacement', observations: [] },
      })
    }
  }
})
process.on('exit', () => fs.rmSync(directory, { recursive: true, force: true }))
`, { service: true });
		try {
			const controller = new AbortController();
			const first = wrapper.api.ocr(
				Buffer.from('first'),
				{ signal: controller.signal },
			).catch((error: unknown) => error);
			await waitFor(
				() => wrapper.serviceApi.pendingServiceRequestsForTesting() > 0,
				'Expected the cancellable shim request to start',
			);
			const firstPid = wrapper.serviceApi.servicePidForTesting()!;
			const second = wrapper.api.ocr(Buffer.from('second')).catch((error: unknown) => error);
			controller.abort();
			const [firstOutcome, secondOutcome] = await Promise.all([
				Promise.race([first, delay(8000, 'timeout')]),
				Promise.race([second, delay(8000, 'timeout')]),
			]);
			expect(firstOutcome).toMatchObject({ kind: 'abort' });
			expect(secondOutcome).toMatchObject({ text: 'replacement' });
			expect(wrapper.serviceApi.servicePidForTesting()).not.toBe(firstPid);
			await waitFor(
				() => !processExists(firstPid),
				'Expected the unresponsive service process to stop',
			);
		} finally {
			wrapper.serviceApi.stopService();
		}
	});

	await test('sends a cancel frame before advancing the queue', async () => {
		await using wrapper = await importWrapper(`#!/usr/bin/env node
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
frame({ type: 'hello', protocolVersion: 1, inputDirectory: directory })
let activeId
let blockNextOcr = true
let buffered = Buffer.alloc(0)
process.stdin.on('data', chunk => {
  buffered = Buffer.concat([buffered, chunk])
  while (buffered.length >= 4) {
    const length = buffered.readUInt32LE(0)
    if (buffered.length < length + 4) return
    const request = JSON.parse(buffered.subarray(4, length + 4))
    buffered = buffered.subarray(length + 4)
    if (request.command === 'cancel' && request.id === activeId) {
      frame({
        id: request.id,
        type: 'error',
        error: { kind: 'abort', message: 'aborted', exitCode: null, stderr: '' },
      })
      activeId = undefined
    } else if (request.command === 'ocr' && blockNextOcr) {
      activeId = request.id
      blockNextOcr = false
    } else if (request.command === 'ocr') {
      frame({
        id: request.id,
        type: 'result',
        result: { page: 1, pageCount: 1, width: 1, height: 1, text: 'next', observations: [] },
      })
    }
  }
})
process.on('exit', () => fs.rmSync(directory, { recursive: true, force: true }))
`, { service: true });
		try {
			const controller = new AbortController();
			const first = wrapper.api.ocr(
				Buffer.from('first'),
				{ signal: controller.signal },
			).catch((error: unknown) => error);
			await waitFor(
				() => wrapper.serviceApi.pendingServiceRequestsForTesting() > 0,
				'Expected the cancellable shim request to start',
			);
			const pid = wrapper.serviceApi.servicePidForTesting();
			const second = wrapper.api.ocr(Buffer.from('second'));
			controller.abort();
			expect(await first).toMatchObject({ kind: 'abort' });
			const result = await Promise.race([
				second,
				delay(500, 'timeout'),
			]);
			expect(result).toMatchObject({ text: 'next' });
			expect(wrapper.serviceApi.servicePidForTesting()).toBe(pid);
		} finally {
			wrapper.serviceApi.stopService();
		}
	});
});
