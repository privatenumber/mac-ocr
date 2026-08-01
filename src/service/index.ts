import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { isMainThread } from 'node:worker_threads';
import { buildArgs } from '../args.ts';
import { MacOcrError } from '../errors.ts';
import { toBuffer } from '../process.ts';
import type { Input, OcrOptions, OcrResult } from '../types.ts';
import {
	serviceAbortFailure,
	serviceFailure,
	serviceInputFailure,
} from './failures.ts';
import { getNativeService, stopNativeService } from './native.ts';

export {
	pendingServiceRequestsForTesting,
	servicePidForTesting,
	startingServicePidForTesting,
} from './native.ts';

type QueuedOcrRequest = {
	buffer?: Buffer;
	retainedBytes: number;
	arguments: string[];
	password?: string;
	signal?: AbortSignal;
	resolve: (result: OcrResult) => void;
	reject: (error: unknown) => void;
	settleAbortListener?: () => void;
};

let serviceEnabled = true;
const queuedOcrRequests: QueuedOcrRequest[] = [];
let serviceQueueRunning = false;
let unstagedRequestBytes = 0;
let unstagedRequestCount = 0;

const maxUnstagedRequestBytes = 64 * 1024 * 1024;
const maxUnstagedRequestCount = 512;

const estimateRetainedMetadataBytes = (arguments_: string[], password?: string): number => {
	let retainedBytes = arguments_.length * 8;
	for (const argument of arguments_) {
		if (typeof argument !== 'string') {
			throw new TypeError('mac-ocr OCR option values must be strings');
		}
		retainedBytes += Math.max(
			argument.length * 2,
			Buffer.byteLength(JSON.stringify(argument)),
		);
	}
	if (password !== undefined) {
		if (typeof password !== 'string') {
			throw new TypeError('mac-ocr OCR password must be a string');
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

const releaseRequestInput = (request: QueuedOcrRequest): void => {
	if (request.buffer) {
		request.buffer = undefined;
		unstagedRequestBytes -= request.retainedBytes;
		unstagedRequestCount -= 1;
	}
};

const rejectQueuedOcrRequests = (error: unknown): void => {
	for (const request of queuedOcrRequests.splice(0)) {
		if (request.signal && request.settleAbortListener) {
			request.signal.removeEventListener('abort', request.settleAbortListener);
		}
		releaseRequestInput(request);
		request.reject(error);
	}
};

const runQueuedOcr = async (request: QueuedOcrRequest): Promise<OcrResult> => {
	const { signal } = request;
	let inputPath: string | undefined;
	let primaryError: unknown;
	try {
		if (signal?.aborted) {
			throw serviceAbortFailure();
		}
		const service = await getNativeService(rejectQueuedOcrRequests, signal);
		if (signal?.aborted) {
			throw serviceAbortFailure();
		}
		const inputName = crypto.randomUUID();
		inputPath = path.join(service.inputDirectory, inputName);
		if (!request.buffer) {
			throw new MacOcrError('mac-ocr OCR queue lost its input buffer', { kind: 'internal' });
		}
		try {
			await fs.writeFile(inputPath, request.buffer, {
				flag: 'wx',
				mode: 0o600,
				signal,
			});
		} catch (error) {
			if (signal?.aborted) {
				throw serviceAbortFailure();
			}
			throw serviceInputFailure(error);
		} finally {
			releaseRequestInput(request);
		}
		return await service.request(inputName, request.arguments, request.password, signal);
	} catch (error) {
		primaryError = error;
		throw error;
	} finally {
		releaseRequestInput(request);
		if (inputPath) {
			await removeStagedInput(inputPath, primaryError !== undefined);
		}
	}
};

const removeQueuedAbortListener = (request: QueuedOcrRequest): void => {
	if (request.signal && request.settleAbortListener) {
		request.signal.removeEventListener('abort', request.settleAbortListener);
	}
};

const drainServiceQueue = async (): Promise<void> => {
	serviceQueueRunning = true;
	try {
		while (queuedOcrRequests.length > 0) {
			const request = queuedOcrRequests.shift()!;
			try {
				const result = await runQueuedOcr(request);
				request.resolve(result);
			} catch (error) {
				request.reject(error);
			} finally {
				removeQueuedAbortListener(request);
			}
		}
	} finally {
		serviceQueueRunning = false;
	}
};

export const ocrWithService = async (input: Input, options?: OcrOptions): Promise<OcrResult> => {
	const inputBuffer = toBuffer(input);
	const arguments_ = buildArgs(options);
	const password = options?.password || process.env.MAC_OCR_PDF_PASSWORD;
	const signal = options?.signal;
	if (signal?.aborted) {
		throw serviceAbortFailure();
	}
	const retainedInputBytes = inputBuffer.buffer.byteLength;
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
		throw new MacOcrError(
			`mac-ocr OCR queue capacity exceeded (${unstagedRequestCount}/${maxUnstagedRequestCount} requests, ${unstagedRequestBytes}/${maxUnstagedRequestBytes} bytes retained)`,
			{
				kind: 'runtime',
				code: 'queue_capacity_exceeded',
			},
		);
	}
	unstagedRequestBytes += retainedBytes;
	unstagedRequestCount += 1;
	const { promise, resolve, reject } = Promise.withResolvers<OcrResult>();
	const request: QueuedOcrRequest = {
		buffer: inputBuffer,
		retainedBytes,
		arguments: arguments_,
		password,
		signal,
		resolve,
		reject,
	};
	if (signal) {
		request.settleAbortListener = () => {
			const index = queuedOcrRequests.indexOf(request);
			if (index === -1) {
				return;
			}
			queuedOcrRequests.splice(index, 1);
			removeQueuedAbortListener(request);
			releaseRequestInput(request);
			request.reject(serviceAbortFailure());
		};
		signal.addEventListener('abort', request.settleAbortListener, { once: true });
	}
	queuedOcrRequests.push(request);
	if (!serviceQueueRunning) {
		drainServiceQueue().catch(rejectQueuedOcrRequests);
	}
	return promise;
};

export const shouldUseService = (): boolean => serviceEnabled && isMainThread;

export const stopService = (): void => {
	rejectQueuedOcrRequests(serviceFailure('mac-ocr service stopped', ''));
	stopNativeService();
};

export const disableServiceForTesting = (): void => {
	stopService();
	serviceEnabled = false;
};
