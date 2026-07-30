import { setTimeout as delay } from 'node:timers/promises';
import { describe, expect, test } from 'manten';
import { ocr } from '../../../src/index.ts';
import {
	pendingServiceRequestsForTesting,
	servicePidForTesting,
} from '../../../src/service/index.ts';
import { fixtureData } from '../../utils.ts';
import { ensureServiceForTesting, waitFor } from './utils.ts';

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
});
