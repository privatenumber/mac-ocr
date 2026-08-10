import crypto from 'node:crypto';
import { addAbortListener } from 'node:events';
import fs from 'node:fs/promises';
import path from 'node:path';
import { buildArgs } from '../args.ts';
import { MacOcrError } from '../errors.ts';
import { toBuffer } from '../process.ts';
import type {
	Input, OcrDocumentResult, OcrOptions, OcrResult,
} from '../types.ts';
import {
	serviceAbortFailure,
	serviceFailure,
	serviceInputFailure,
} from './failures.ts';
import {
	getNativeService, stopNativeService, type NativeOperation, type NativeService, type NativeStream,
} from './native.ts';
import type { NativeArtifact } from './protocol.ts';

export {
	pendingServiceRequestsForTesting,
	servicePidForTesting,
	startingServicePidForTesting,
} from './native.ts';

type QueuedRequest = {
	type: 'unary' | 'stream';
	operation: NativeOperation;
	buffer?: Buffer;
	retainedBytes: number;
	arguments?: string[];
	password?: string;
	signal?: AbortSignal;
	resolve?: (result: unknown) => void;
	reject: (error: unknown) => void;
	start?: (stream: NativeStream) => void;
	abortSubscription?: ReturnType<typeof addAbortListener>;
	admitted: boolean;
};

const queuedRequests: QueuedRequest[] = [];
let serviceQueueRunning = false;
let unstagedRequestBytes = 0;
let unstagedRequestCount = 0;

const maxUnstagedRequestBytes = 64 * 1024 * 1024;
const maxUnstagedRequestCount = 512;

const estimateRetainedMetadataBytes = (
	arguments_: string[] | undefined,
	password?: string,
): number => {
	let retainedBytes = (arguments_?.length ?? 0) * 8;
	for (const argument of arguments_ ?? []) {
		if (typeof argument !== 'string') {
			throw new TypeError('mac-ocr service option values must be strings');
		}
		retainedBytes += Math.max(
			argument.length * 2,
			Buffer.byteLength(JSON.stringify(argument)),
		);
	}
	if (password !== undefined) {
		if (typeof password !== 'string') {
			throw new TypeError('mac-ocr PDF password must be a string');
		}
		retainedBytes += Math.max(
			password.length * 2,
			Buffer.byteLength(JSON.stringify(password)),
		);
	}
	return retainedBytes;
};

const removeStagedInput = async (inputPath: string, suppressFailure: boolean): Promise<void> => {
	try {
		await fs.rm(inputPath, { force: true });
	} catch (error) {
		if (!suppressFailure) {
			throw serviceInputFailure(error);
		}
	}
};

const retireMissingServiceDirectory = async (inputDirectory: string): Promise<void> => {
	try {
		await fs.access(inputDirectory);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
			stopNativeService(true);
		}
	}
};

const releaseRequestInput = (request: QueuedRequest): void => {
	if (!request.admitted) {
		return;
	}
	request.admitted = false;
	request.buffer = undefined;
	unstagedRequestBytes -= request.retainedBytes;
	unstagedRequestCount -= 1;
};

const removeQueuedAbortListener = (request: QueuedRequest): void => {
	request.abortSubscription?.[Symbol.dispose]();
	request.abortSubscription = undefined;
};

const rejectRequest = (request: QueuedRequest, error: unknown): void => {
	removeQueuedAbortListener(request);
	releaseRequestInput(request);
	request.reject(error);
};

const rejectQueuedRequests = (error: unknown): void => {
	for (const request of queuedRequests.splice(0)) {
		rejectRequest(request, error);
	}
};

const resultForRequest = async (
	service: NativeService,
	request: QueuedRequest,
	inputName: string | undefined,
): Promise<unknown> => {
	const outputName = request.operation === 'searchable-pdf' ? crypto.randomUUID() : undefined;
	const nativeRequest = {
		operation: request.operation,
		inputName,
		arguments: request.arguments,
		password: request.password,
		outputName,
	};
	if (request.type === 'stream') {
		const stream = service.stream(nativeRequest, request.signal);
		request.start!(stream);
		await stream.done;
		await retireMissingServiceDirectory(service.inputDirectory);
		return undefined;
	}
	try {
		const result = await service.request(nativeRequest, request.signal);
		if (request.operation !== 'searchable-pdf') {
			return result;
		}
		const artifact = result as NativeArtifact;
		const outputPath = path.join(service.inputDirectory, artifact.name);
		try {
			const output = await fs.readFile(outputPath);
			if (output.byteLength !== artifact.size) {
				throw new MacOcrError('mac-ocr service returned a truncated PDF artifact', { kind: 'internal' });
			}
			return output;
		} finally {
			await fs.rm(outputPath, { force: true }).catch(() => {});
		}
	} catch (error) {
		if (outputName) {
			await fs.rm(path.join(service.inputDirectory, outputName), { force: true }).catch(() => {});
		}
		await retireMissingServiceDirectory(service.inputDirectory);
		throw error;
	}
};

const runQueuedRequest = async (request: QueuedRequest): Promise<void> => {
	let inputPath: string | undefined;
	let primaryError: unknown;
	try {
		if (request.signal?.aborted) {
			throw serviceAbortFailure();
		}
		const service = await getNativeService(rejectQueuedRequests, request.signal);
		if (request.signal?.aborted) {
			throw serviceAbortFailure();
		}
		let inputName: string | undefined;
		if (request.buffer) {
			inputName = crypto.randomUUID();
			inputPath = path.join(service.inputDirectory, inputName);
			try {
				await fs.writeFile(inputPath, request.buffer, {
					flag: 'wx',
					mode: 0o600,
					signal: request.signal,
				});
			} catch (error) {
				if (request.signal?.aborted) {
					throw serviceAbortFailure();
				}
				if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
					stopNativeService();
				}
				throw serviceInputFailure(error);
			} finally {
				releaseRequestInput(request);
			}
		}
		const result = await resultForRequest(service, request, inputName);
		request.resolve?.(result);
	} catch (error) {
		primaryError = error;
		request.reject(error);
	} finally {
		releaseRequestInput(request);
		if (inputPath) {
			await removeStagedInput(inputPath, primaryError !== undefined);
		}
	}
};

const drainServiceQueue = async (): Promise<void> => {
	serviceQueueRunning = true;
	try {
		while (queuedRequests.length > 0) {
			const request = queuedRequests.shift()!;
			removeQueuedAbortListener(request);
			await runQueuedRequest(request);
		}
	} finally {
		serviceQueueRunning = false;
	}
};

const queueRequest = (
	type: QueuedRequest['type'],
	operation: NativeOperation,
	input: Input | undefined,
	arguments_: string[] | undefined,
	password: string | undefined,
	signal: AbortSignal | undefined,
): Promise<unknown> => {
	if (signal?.aborted) {
		return Promise.reject(serviceAbortFailure());
	}
	const buffer = input === undefined ? undefined : toBuffer(input);
	const retainedInputBytes = buffer?.buffer.byteLength ?? 0;
	const retainedMetadataBytes = estimateRetainedMetadataBytes(arguments_, password);
	const retainedBytes = retainedInputBytes + retainedMetadataBytes;
	const allowsOversizedInput = (
		unstagedRequestCount === 0
		&& retainedInputBytes > maxUnstagedRequestBytes
		&& retainedMetadataBytes <= maxUnstagedRequestBytes
	);
	if (
		unstagedRequestCount >= maxUnstagedRequestCount
		|| (
			unstagedRequestBytes + retainedBytes > maxUnstagedRequestBytes
			&& !allowsOversizedInput
		)
	) {
		return Promise.reject(new MacOcrError(
			`mac-ocr service queue capacity exceeded (${unstagedRequestCount}/${maxUnstagedRequestCount} requests, ${unstagedRequestBytes}/${maxUnstagedRequestBytes} bytes retained)`,
			{
				kind: 'runtime',
				code: 'queue_capacity_exceeded',
			},
		));
	}
	const { promise, resolve, reject } = Promise.withResolvers<unknown>();
	const request: QueuedRequest = {
		type,
		operation,
		buffer,
		retainedBytes,
		arguments: arguments_,
		password,
		signal,
		resolve,
		reject,
		admitted: true,
	};
	if (type === 'stream') {
		const stream = Promise.withResolvers<NativeStream>();
		request.resolve = undefined;
		request.start = stream.resolve;
		request.reject = stream.reject;
		request.abortSubscription = signal && addAbortListener(signal, () => {
			const index = queuedRequests.indexOf(request);
			if (index === -1) {
				return;
			}
			queuedRequests.splice(index, 1);
			rejectRequest(request, serviceAbortFailure());
		});
		unstagedRequestBytes += retainedBytes;
		unstagedRequestCount += 1;
		queuedRequests.push(request);
		if (!serviceQueueRunning) {
			drainServiceQueue().catch(rejectQueuedRequests);
		}
		return stream.promise;
	}
	if (signal) {
		request.abortSubscription = addAbortListener(signal, () => {
			const index = queuedRequests.indexOf(request);
			if (index === -1) {
				return;
			}
			queuedRequests.splice(index, 1);
			rejectRequest(request, serviceAbortFailure());
		});
	}
	unstagedRequestBytes += retainedBytes;
	unstagedRequestCount += 1;
	queuedRequests.push(request);
	if (!serviceQueueRunning) {
		drainServiceQueue().catch(rejectQueuedRequests);
	}
	return promise;
};

const isValidPage = (page: OcrResult, expectedPageCount?: number): boolean => (
	Number.isSafeInteger(page.page)
	&& Number.isSafeInteger(page.pageCount)
	&& page.page >= 1
	&& page.pageCount >= 1
	&& page.page <= page.pageCount
	&& (expectedPageCount === undefined || page.pageCount === expectedPageCount)
);

export const ocrWithService = async (input: Input, options?: OcrOptions): Promise<OcrResult> => {
	const result = await queueRequest(
		'unary',
		'ocr',
		input,
		buildArgs(options),
		options?.password || process.env.MAC_OCR_PDF_PASSWORD,
		options?.signal,
	);
	return result as OcrResult;
};

export const ocrDocumentWithService = (
	input: Input,
	arguments_: string[],
	password: string | undefined,
	signal: AbortSignal | undefined,
): Promise<OcrDocumentResult> => queueRequest(
	'unary',
	'document',
	input,
	arguments_,
	password,
	signal,
) as Promise<OcrDocumentResult>;

export const ocrDocumentPagesWithService = (
	input: Input,
	arguments_: string[],
	password: string | undefined,
	signal: AbortSignal | undefined,
): Promise<NativeStream> => queueRequest(
	'stream',
	'document-pages',
	input,
	arguments_,
	password,
	signal,
) as Promise<NativeStream>;

export const ocrPagesWithService = (
	input: Input,
	options?: OcrOptions,
): AsyncIterable<OcrResult> => {
	let consumed = false;
	const iterate = async function* iterate(): AsyncGenerator<OcrResult> {
		if (consumed) {
			throw new MacOcrError(
				'This ocr.pages() result was already consumed. Call ocr.pages() again to re-read it.',
				{ kind: 'usage' },
			);
		}
		consumed = true;
		const stream = await queueRequest(
			'stream',
			'ocr-pages',
			input,
			buildArgs(options),
			options?.password || process.env.MAC_OCR_PDF_PASSWORD,
			options?.signal,
		) as NativeStream & AsyncIterable<OcrResult>;
		let completed = false;
		let expectedPageCount: number | undefined;
		const seenPages = new Set<number>();
		let invalidPageMetadata = false;
		try {
			for await (const page of stream) {
				if (!isValidPage(page, expectedPageCount) || seenPages.has(page.page)) {
					invalidPageMetadata = true;
					continue;
				}
				expectedPageCount = page.pageCount;
				seenPages.add(page.page);
				yield page;
			}
			completed = true;
		} finally {
			if (!completed) {
				await stream.cancel();
			}
		}
		if (expectedPageCount === undefined) {
			throw new MacOcrError('mac-ocr ocr produced no output', { kind: 'parse' });
		}
		if (
			invalidPageMetadata
			|| seenPages.size !== expectedPageCount
		) {
			throw new MacOcrError(
				`mac-ocr ocr produced ${seenPages.size} of ${expectedPageCount} pages - some output could not be parsed`,
				{ kind: 'parse' },
			);
		}
	};
	return { [Symbol.asyncIterator]: iterate };
};

export const searchablePdfWithService = async (
	input: Input,
	arguments_: string[],
	password: string | undefined,
	signal: AbortSignal | undefined,
): Promise<Uint8Array> => {
	const result = await queueRequest(
		'unary',
		'searchable-pdf',
		input,
		arguments_,
		password,
		signal,
	);
	return result as Uint8Array;
};

export const supportedLanguagesWithService = async (
	fast: boolean | undefined,
): Promise<string[]> => {
	const result = await queueRequest(
		'unary',
		'languages',
		undefined,
		fast ? ['--fast'] : [],
		undefined,
		undefined,
	);
	return result as string[];
};

export const stopService = (): void => {
	rejectQueuedRequests(serviceFailure('mac-ocr service stopped', ''));
	stopNativeService();
};
