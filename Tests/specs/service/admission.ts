import { setTimeout } from 'node:timers/promises';
import { describe, expect, test } from 'manten';
import { importWrapper } from '../../utils.ts';
import { serviceShim } from './utils.ts';

const stalledService = '#!/usr/bin/env node\nsetTimeout(() => {}, 30_000)\n';

await describe('admission', () => {
	test('rejects queued input beyond the byte budget', async () => {
		await using wrapper = await importWrapper(stalledService, { service: true });
		const input = Buffer.alloc(1024 * 1024);
		const requests = Array.from(
			{ length: 65 },
			() => wrapper.api.ocr(input).catch((error: unknown) => error),
		);
		try {
			const outcome = await Promise.race([
				requests.at(-1)!,
				setTimeout(100, 'pending'),
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

	test('accounts for backing storage retained by byte views', async () => {
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
				setTimeout(100, 'pending'),
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

	test('accounts for metadata retained by queued requests', async () => {
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
				setTimeout(100, 'pending'),
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

	test('rejects malformed options without poisoning admission state', async () => {
		await using wrapper = await importWrapper(stalledService, { service: true });
		const pending: Promise<unknown>[] = [];
		try {
			const malformedMetadata = wrapper.api.ocr(Buffer.alloc(0), {
				customWords: [1 as never],
			}).catch((error: unknown) => error);
			const malformedSignal = wrapper.api.ocr(Buffer.alloc(0), {
				signal: {} as AbortSignal,
			}).catch((error: unknown) => error);
			pending.push(malformedMetadata, malformedSignal);
			expect(await Promise.race([
				malformedMetadata,
				setTimeout(100, 'pending'),
			])).toBeInstanceOf(TypeError);
			expect(await Promise.race([
				malformedSignal,
				setTimeout(100, 'pending'),
			])).toBeInstanceOf(TypeError);

			const input = Buffer.alloc(1024 * 1024);
			const requests = Array.from(
				{ length: 65 },
				() => wrapper.api.ocr(input).catch((error: unknown) => error),
			);
			pending.push(...requests);
			expect(await Promise.race([
				requests.at(-1)!,
				setTimeout(100, 'pending'),
			])).toMatchObject({
				kind: 'runtime',
				code: 'queue_capacity_exceeded',
			});
		} finally {
			wrapper.serviceApi.stopService();
			await Promise.all(pending);
		}
	});

	test('rejects queued requests beyond the count budget', async () => {
		await using wrapper = await importWrapper(stalledService, { service: true });
		const requests = Array.from(
			{ length: 513 },
			() => wrapper.api.ocr(Buffer.alloc(0)).catch((error: unknown) => error),
		);
		try {
			const outcome = await Promise.race([
				requests.at(-1)!,
				setTimeout(100, 'pending'),
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

	test('releases queued capacity when a request is aborted', async () => {
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
				setTimeout(100, 'pending'),
			])).toBe('pending');
		} finally {
			wrapper.serviceApi.stopService();
			await Promise.all([...requests, replacement]);
		}
	});

	test('allows one oversized input when no other input is unstaged', async () => {
		await using wrapper = await importWrapper(stalledService, { service: true });
		const request = wrapper.api.ocr(
			Buffer.alloc(65 * 1024 * 1024),
		).catch((error: unknown) => error);
		try {
			expect(await Promise.race([
				request,
				setTimeout(100, 'pending'),
			])).toBe('pending');
		} finally {
			wrapper.serviceApi.stopService();
			await request;
		}
	});

	test('recovers after a request frame exceeds the protocol limit', async () => {
		await using wrapper = await importWrapper(serviceShim({
			onRequest: `if (request.operation === 'ocr') {
  complete(request, { page: 1, pageCount: 1, width: 1, height: 1, text: 'recovered', observations: [] })
}`,
		}), { service: true });
		const oversized = await wrapper.api.ocr(Buffer.alloc(0), {
			customWords: [String.fromCodePoint(0x1_F6_00).repeat((64 * 1024 * 1024 - 64) / 4)],
		}).catch((error: unknown) => error);
		expect(oversized).toMatchObject({ kind: 'usage' });
		expect(await wrapper.api.ocr(Buffer.from('next'))).toMatchObject({ text: 'recovered' });
	});
}, { parallel: 2 });
