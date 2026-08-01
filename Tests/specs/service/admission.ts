import { setTimeout as delay } from 'node:timers/promises';
import { describe, expect, test } from 'manten';
import { importWrapper } from '../../utils.ts';

const stalledService = '#!/usr/bin/env node\nsetTimeout(() => {}, 30_000)\n';

await describe('admission', async () => {
	await test('rejects queued input beyond the byte budget', async () => {
		await using wrapper = await importWrapper(stalledService, { service: true });
		const input = Buffer.alloc(1024 * 1024);
		const requests = Array.from(
			{ length: 65 },
			() => wrapper.api.ocr(input).catch((error: unknown) => error),
		);
		try {
			const outcome = await Promise.race([
				requests.at(-1)!,
				delay(100, 'pending'),
			]);
			expect(outcome).toMatchObject({
				kind: 'runtime',
				code: 'queue_capacity_exceeded',
			});
		} finally {
			wrapper.serviceApi.stopService();
			await Promise.all(requests);
		}
	});

	await test('accounts for backing storage retained by byte views', async () => {
		await using wrapper = await importWrapper(stalledService, { service: true });
		const requests = Array.from(
			{ length: 33 },
			() => wrapper.api.ocr(
				Buffer.alloc(2 * 1024 * 1024).subarray(0, 1),
			).catch((error: unknown) => error),
		);
		try {
			const outcome = await Promise.race([
				requests.at(-1)!,
				delay(100, 'pending'),
			]);
			expect(outcome).toMatchObject({
				kind: 'runtime',
				code: 'queue_capacity_exceeded',
			});
		} finally {
			wrapper.serviceApi.stopService();
			await Promise.all(requests);
		}
	});

	await test('accounts for metadata retained by queued requests', async () => {
		await using wrapper = await importWrapper(stalledService, { service: true });
		const requests = Array.from(
			{ length: 33 },
			(_, index) => wrapper.api.ocr(Buffer.alloc(0), {
				customWords: [String.fromCodePoint(33 + index).repeat(1024 * 1024)],
			}).catch((error: unknown) => error),
		);
		try {
			const outcome = await Promise.race([
				requests.at(-1)!,
				delay(100, 'pending'),
			]);
			expect(outcome).toMatchObject({
				kind: 'runtime',
				code: 'queue_capacity_exceeded',
			});
		} finally {
			wrapper.serviceApi.stopService();
			await Promise.all(requests);
		}
	});

	await test('rejects queued requests beyond the count budget', async () => {
		await using wrapper = await importWrapper(stalledService, { service: true });
		const requests = Array.from(
			{ length: 513 },
			() => wrapper.api.ocr(Buffer.alloc(0)).catch((error: unknown) => error),
		);
		try {
			const outcome = await Promise.race([
				requests.at(-1)!,
				delay(100, 'pending'),
			]);
			expect(outcome).toMatchObject({
				kind: 'runtime',
				code: 'queue_capacity_exceeded',
			});
		} finally {
			wrapper.serviceApi.stopService();
			await Promise.all(requests);
		}
	});

	await test('releases queued capacity when a request is aborted', async () => {
		await using wrapper = await importWrapper(stalledService, { service: true });
		const input = Buffer.alloc(1024 * 1024);
		const requests = Array.from(
			{ length: 63 },
			() => wrapper.api.ocr(input).catch((error: unknown) => error),
		);
		const controller = new AbortController();
		const aborted = wrapper.api.ocr(
			input,
			{ signal: controller.signal },
		).catch((error: unknown) => error);
		requests.push(aborted);
		controller.abort();
		expect(await aborted).toMatchObject({ kind: 'abort' });
		const replacement = wrapper.api.ocr(input).catch((error: unknown) => error);
		try {
			expect(await Promise.race([
				replacement,
				delay(100, 'pending'),
			])).toBe('pending');
		} finally {
			wrapper.serviceApi.stopService();
			await Promise.all([...requests, replacement]);
		}
	});

	await test('allows one oversized input when no other input is unstaged', async () => {
		await using wrapper = await importWrapper(stalledService, { service: true });
		const request = wrapper.api.ocr(
			Buffer.alloc(65 * 1024 * 1024),
		).catch((error: unknown) => error);
		try {
			expect(await Promise.race([
				request,
				delay(100, 'pending'),
			])).toBe('pending');
		} finally {
			wrapper.serviceApi.stopService();
			await request;
		}
	});
});
