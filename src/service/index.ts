import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { isMainThread } from 'node:worker_threads';
import { buildArgs } from '../args.ts';
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
	buffer: Buffer;
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

const removeStagedInput = async (inputPath: string, suppressFailure: boolean): Promise<void> => {
	try {
		await fs.rm(inputPath, { force: true });
	} catch (error) {
		if (!suppressFailure) {
			throw serviceInputFailure(error);
		}
	}
};

const rejectQueuedOcrRequests = (error: unknown): void => {
	for (const request of queuedOcrRequests.splice(0)) {
		if (request.signal && request.settleAbortListener) {
			request.signal.removeEventListener('abort', request.settleAbortListener);
		}
		request.reject(error);
	}
};

const runQueuedOcr = async (
	buffer: Buffer,
	arguments_: string[],
	password?: string,
	signal?: AbortSignal,
): Promise<OcrResult> => {
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
		try {
			await fs.writeFile(inputPath, buffer, {
				flag: 'wx',
				mode: 0o600,
				signal,
			});
		} catch (error) {
			if (signal?.aborted) {
				throw serviceAbortFailure();
			}
			throw serviceInputFailure(error);
		}
		return await service.request(inputName, arguments_, password, signal);
	} catch (error) {
		primaryError = error;
		throw error;
	} finally {
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
				const result = await runQueuedOcr(
					request.buffer,
					request.arguments,
					request.password,
					request.signal,
				);
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
	const buffer = Buffer.from(inputBuffer);
	const { promise, resolve, reject } = Promise.withResolvers<OcrResult>();
	const request: QueuedOcrRequest = {
		buffer,
		arguments: arguments_,
		password,
		signal,
		resolve,
		reject,
	};
	if (signal) {
		request.settleAbortListener = () => {
			const index = queuedOcrRequests.indexOf(request);
			if (index !== -1) {
				queuedOcrRequests.splice(index, 1);
				removeQueuedAbortListener(request);
			}
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
