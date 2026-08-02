import crypto from 'node:crypto';
import { addAbortListener } from 'node:events';
import fs from 'node:fs/promises';
import path from 'node:path';
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
	abortSubscription?: ReturnType<typeof addAbortListener>;
};

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

const retireMissingServiceDirectory = async (inputDirectory: string): Promise<void> => {
	try {
		await fs.access(inputDirectory);
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
			stopNativeService();
		}
	}
};

const releaseRequestInput = (request: QueuedOcrRequest): void => {
	if (request.buffer) {
		// Clearing the buffer makes admission release idempotent across nested cleanup paths.
		request.buffer = undefined;
		unstagedRequestBytes -= request.retainedBytes;
		unstagedRequestCount -= 1;
	}
};

const removeQueuedAbortListener = (request: QueuedOcrRequest): void => {
	request.abortSubscription?.[Symbol.dispose]();
	request.abortSubscription = undefined;
};

const rejectQueuedOcrRequests = (error: unknown): void => {
	for (const request of queuedOcrRequests.splice(0)) {
		removeQueuedAbortListener(request);
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
			if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
				stopNativeService();
			}
			throw serviceInputFailure(error);
		} finally {
			releaseRequestInput(request);
		}
		try {
			return await service.request(inputName, request.arguments, request.password, signal);
		} catch (error) {
			await retireMissingServiceDirectory(service.inputDirectory);
			throw error;
		}
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
const drainServiceQueue = async (): Promise<void> => {
	serviceQueueRunning = true;
	try {
		while (queuedOcrRequests.length > 0) {
			const request = queuedOcrRequests.shift()!;
			removeQueuedAbortListener(request);
			try {
				const result = await runQueuedOcr(request);
				request.resolve(result);
			} catch (error) {
				request.reject(error);
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
		request.abortSubscription = addAbortListener(signal, () => {
			const index = queuedOcrRequests.indexOf(request);
			if (index === -1) {
				return;
			}
			queuedOcrRequests.splice(index, 1);
			removeQueuedAbortListener(request);
			releaseRequestInput(request);
			request.reject(serviceAbortFailure());
		});
	}
	unstagedRequestBytes += retainedBytes;
	unstagedRequestCount += 1;
	queuedOcrRequests.push(request);
	if (!serviceQueueRunning) {
		drainServiceQueue().catch(rejectQueuedOcrRequests);
	}
	return promise;
};

export const stopService = (): void => {
	rejectQueuedOcrRequests(serviceFailure('mac-ocr service stopped', ''));
	stopNativeService();
};
