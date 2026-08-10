import { setTimeout } from 'node:timers/promises';
import fs from 'node:fs/promises';
import path from 'node:path';
import { describe, expect, test } from 'manten';
import { ocr } from '../../../src/index.ts';
import {
	pendingServiceRequestsForTesting,
	servicePidForTesting,
} from '../../../src/service/index.ts';
import { fixtureData, importWrapper, processExists } from '../../utils.ts';
import {
	ensureServiceForTesting,
	serviceShim,
	waitFor,
} from './utils.ts';

await describe('cancellation', () => {
	test('rejects a pre-aborted service request', async () => {
		const pid = await ensureServiceForTesting();
		const controller = new AbortController();
		controller.abort();
		const error = await ocr(
			fixtureData('hello.png'),
			{ signal: controller.signal },
		).catch((error_: unknown) => error_);
		expect(error).toMatchObject({ kind: 'abort' });
		expect((error as Error).message).toMatch(/abort/i);
		expect(servicePidForTesting()).toBe(pid);
	});

	test('aborts a stalled startup without blocking the next request', async () => {
		await using wrapper = await importWrapper(`#!/usr/bin/env node
setTimeout(() => {}, 30_000)
`, { service: true });
		const controller = new AbortController();
		controller.signal.addEventListener('abort', event => event.stopImmediatePropagation());
		const first = wrapper.api.ocr(
			Buffer.from('first'),
			{ signal: controller.signal },
		).catch((error: unknown) => error);
		await waitFor(
			() => wrapper.serviceApi.startingServicePidForTesting() !== undefined,
			'Expected the stalled service process to start',
		);
		const firstPid = wrapper.serviceApi.startingServicePidForTesting()!;
		await fs.writeFile(wrapper.binaryPath, serviceShim({
			onRequest: `if (request.operation === 'ocr') {
			  complete(request, { page: 1, pageCount: 1, width: 1, height: 1, text: 'ok', observations: [] })
			}`,
		}));
		const second = wrapper.api.ocr(Buffer.from('second')).catch((error: unknown) => error);
		controller.abort();
		expect(await first).toMatchObject({ kind: 'abort' });
		await waitFor(
			() => !processExists(firstPid),
			'Expected the aborted startup process to stop',
		);
		const result = await Promise.race([
			second,
			setTimeout(2000, 'timeout'),
		]);
		expect(result).toMatchObject({ text: 'ok' });
	});

	test('removes an aborted queued request before staging', async () => {
		const pid = await ensureServiceForTesting();
		const blocker = ocr(fixtureData('document-photo.png'));
		await waitFor(
			() => pendingServiceRequestsForTesting() > 0,
			'Expected the blocking service request to start',
		);
		const controller = new AbortController();
		// `addAbortListener()` must still run when another consumer stops propagation.
		controller.signal.addEventListener('abort', event => event.stopImmediatePropagation());
		const queued = ocr(fixtureData('hello.png'), { signal: controller.signal });
		controller.abort();
		const outcome = await Promise.race([
			queued.catch((error: unknown) => error),
			setTimeout(250, 'timeout'),
		]);
		expect(outcome).toMatchObject({ kind: 'abort' });
		await blocker;
		expect(servicePidForTesting()).toBe(pid);
	});

	test('cancels active Vision work without stopping the service', async () => {
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
		controller.signal.addEventListener('abort', event => event.stopImmediatePropagation());
		controller.abort();
		const error = await pending.catch((error_: unknown) => error_);
		expect(error).toMatchObject({ kind: 'abort' });
		const result = await ocr(fixtureData('hello.png'));
		expect(result.text).toContain('Hello World');
		expect(servicePidForTesting()).toBe(pid);
	});

	test('preserves caller abort when the service exits during cancellation', async () => {
		await using wrapper = await importWrapper(serviceShim({
			onRequest: "if (request.command === 'cancel') process.exit(1)",
		}), { service: true });
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

	test('preserves caller abort when a PDF request completes after cancellation', async () => {
		await using wrapper = await importWrapper(serviceShim({
			onRequest: `if (request.operation === 'searchable-pdf') {
  activeRequest = request
} else if (request.command === 'cancel' && request.id === activeRequest?.id) {
  const artifactPath = path.join(directory, activeRequest.outputName)
  fs.writeFileSync(artifactPath, Buffer.from('%PDF'))
  fs.writeFileSync(path.join(__dirname, 'artifact-path'), artifactPath)
  complete(activeRequest, { name: activeRequest.outputName, size: 4 })
} else if (request.operation === 'ocr') {
  complete(request, { page: 1, pageCount: 1, width: 1, height: 1, text: 'next', observations: [] })
}`,
			setup: 'let activeRequest',
		}), { service: true });
		const controller = new AbortController();
		const pending = wrapper.api.createSearchablePdf(
			Buffer.from('pdf'),
			{ signal: controller.signal },
		).catch((error: unknown) => error);
		await waitFor(
			() => wrapper.serviceApi.pendingServiceRequestsForTesting() > 0,
			'Expected the PDF request to start',
		);
		controller.abort();
		expect(await pending).toMatchObject({ kind: 'abort' });
		const artifactPath = await fs.readFile(
			path.join(path.dirname(wrapper.binaryPath), 'artifact-path'),
			'utf8',
		);
		await expect(fs.access(artifactPath)).rejects.toMatchObject({ code: 'ENOENT' });
		expect(await wrapper.api.ocr(Buffer.from('next'))).toMatchObject({ text: 'next' });
	});

	test('rejects a late page after cancellation', async () => {
		await using wrapper = await importWrapper(serviceShim({
			setup: 'let activeRequest',
			onRequest: `if (request.operation === 'ocr-pages') {
  activeRequest = request
} else if (request.command === 'cancel' && request.id === activeRequest?.id) {
  item(activeRequest, 0, { page: 1, pageCount: 1, width: 1, height: 1, text: 'late page', observations: [] })
  frame({
    id: activeRequest.id,
    type: 'error',
    error: { kind: 'abort', message: 'aborted', exitCode: null, stderr: '' },
  })
}`,
		}), { service: true });
		const controller = new AbortController();
		const iterator = wrapper.api.ocr.pages(
			Buffer.from('pages'),
			{ signal: controller.signal },
		)[Symbol.asyncIterator]();
		const next = iterator.next().catch((error: unknown) => error);
		await waitFor(
			() => wrapper.serviceApi.pendingServiceRequestsForTesting() > 0,
			'Expected the page stream to start',
		);
		controller.abort();
		expect(await next).toMatchObject({ kind: 'abort' });
		await iterator.return?.();
	});

	test('replaces a service that does not acknowledge cancellation', async () => {
		await using wrapper = await importWrapper(serviceShim({
			setup: `const marker = path.join(__dirname, '.started')
const replacement = fs.existsSync(marker)
fs.writeFileSync(marker, '')`,
			onRequest: `if (replacement && request.operation === 'ocr') {
			  complete(request, { page: 1, pageCount: 1, width: 1, height: 1, text: 'replacement', observations: [] })
			}`,
		}), { service: true });
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
			Promise.race([first, setTimeout(8000, 'timeout')]),
			Promise.race([second, setTimeout(8000, 'timeout')]),
		]);
		expect(firstOutcome).toMatchObject({ kind: 'abort' });
		expect(secondOutcome).toMatchObject({ text: 'replacement' });
		expect(wrapper.serviceApi.servicePidForTesting()).not.toBe(firstPid);
		await waitFor(
			() => !processExists(firstPid),
			'Expected the unresponsive service process to stop',
		);
	});

	test('sends a cancel frame before advancing the queue', async () => {
		await using wrapper = await importWrapper(serviceShim({
			setup: `let activeId
let blockNextOcr = true`,
			onRequest: `if (request.command === 'cancel' && request.id === activeId) {
  frame({
    id: request.id,
    type: 'error',
    error: { kind: 'abort', message: 'aborted', exitCode: null, stderr: '' },
  })
  activeId = undefined
} else if (request.operation === 'ocr' && blockNextOcr) {
  activeId = request.id
  blockNextOcr = false
} else if (request.operation === 'ocr') {
  complete(request, { page: 1, pageCount: 1, width: 1, height: 1, text: 'next', observations: [] })
}`,
		}), { service: true });
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
			setTimeout(2000, 'timeout'),
		]);
		expect(result).toMatchObject({ text: 'next' });
		expect(wrapper.serviceApi.servicePidForTesting()).toBe(pid);
	});

	test('replaces an unresponsive page stream without rejecting queued work', async () => {
		await using wrapper = await importWrapper(serviceShim({
			setup: `const marker = path.join(__dirname, '.started')
const replacement = fs.existsSync(marker)
fs.writeFileSync(marker, '')
let activePageRequest`,
			onRequest: `if (replacement && request.operation === 'ocr') {
  complete(request, { page: 1, pageCount: 1, width: 1, height: 1, text: 'replacement', observations: [] })
} else if (request.operation === 'ocr-pages') {
  activePageRequest = request
} else if (request.command === 'pull' && request.id === activePageRequest?.id) {
  item(request, 0, { page: 1, pageCount: 1, width: 1, height: 1, text: 'page', observations: [] })
}`,
		}), { service: true });
		const iterator = wrapper.api.ocr.pages(Buffer.from('pages'))[Symbol.asyncIterator]();
		expect(await iterator.next()).toMatchObject({ value: { text: 'page' } });
		const queued = wrapper.api.ocr(Buffer.from('next'));
		await iterator.return?.();
		expect(await Promise.race([
			queued,
			setTimeout(8000, 'timeout'),
		])).toMatchObject({ text: 'replacement' });
	});
}, { parallel: false });
