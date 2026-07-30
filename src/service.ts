import childProcess from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { isMainThread } from 'node:worker_threads';
import { buildArgs } from './args.ts';
import { MacOcrError, type MacOcrErrorKind } from './errors.ts';
import { binaryPath, toBuffer } from './process.ts';
import type { Input, OcrOptions, OcrResult } from './types.ts';

const protocolVersion = 1;
const maxFrameBytes = 64 * 1024 * 1024;
const serviceDirectoryPattern = /^mac-ocr-service-\d+-[0-9A-Fa-f-]{36}$/;

const removeServiceDirectory = (directory: string): void => {
	// Swift owns normal cleanup; Node covers crashes before Swift's defer runs.
	fs.rm(directory, {
		recursive: true,
		force: true,
	}).catch(() => {});
};

type NativeHello = {
	type: 'hello';
	protocolVersion: number;
	inputDirectory: string;
};

type NativeError = {
	kind: MacOcrErrorKind;
	code?: string;
	message: string;
	exitCode?: number | null;
	stderr: string;
};

type NativeResponse = {
	id: number;
	type: 'result';
	result: OcrResult;
} | {
	id: number;
	type: 'error';
	error: NativeError;
};

type PendingRequest = {
	id: number;
	resolve: (result: OcrResult) => void;
	reject: (error: unknown) => void;
	signal?: AbortSignal;
	cancelAbortListener?: () => void;
};

type QueuedOcrRequest = {
	buffer: Buffer;
	arguments: string[];
	password?: string;
	signal?: AbortSignal;
	resolve: (result: OcrResult) => void;
	reject: (error: unknown) => void;
	settleAbortListener?: () => void;
};

type Service = {
	pid: number;
	inputDirectory: string;
	pendingRequests: () => number;
	request: (
		inputName: string,
		arguments_: string[],
		password?: string,
		signal?: AbortSignal,
	) => Promise<OcrResult>;
	stop: () => void;
};

type ServiceState = {
	promise?: Promise<Service>;
	active?: Service;
	stopStarting?: () => void;
	startingPid?: number;
};

let serviceEnabled = true;
// Callback identity prevents a stopped service from clearing its replacement.
let serviceState: ServiceState | undefined;
const queuedOcrRequests: QueuedOcrRequest[] = [];
let serviceQueueRunning = false;

const normalizeProtocolString = (_key: string, value: unknown): unknown => (
	typeof value === 'string' ? value.toWellFormed() : value
);

const encodeFrame = (value: unknown): Buffer => {
	const payload = Buffer.from(JSON.stringify(value, normalizeProtocolString), 'utf8');
	if (payload.byteLength > maxFrameBytes) {
		throw new MacOcrError('mac-ocr service request exceeds the 64 MiB limit', { kind: 'usage' });
	}
	const header = Buffer.allocUnsafe(4);
	header.writeUInt32LE(payload.byteLength);
	return Buffer.concat([header, payload]);
};

const serviceFailure = (
	message: string,
	stderr: string,
	cause?: unknown,
): MacOcrError => new MacOcrError(stderr || message, {
	kind: 'runtime',
	stderr,
	cause,
});

const serviceSpawnFailure = (error: unknown, stderr: string): MacOcrError => {
	const detail = error instanceof Error ? error.message : String(error);
	return new MacOcrError(`mac-ocr service failed to start: ${detail}`, {
		kind: 'spawn',
		stderr,
		cause: error,
	});
};

const serviceAbortFailure = (stderr = ''): MacOcrError => new MacOcrError(
	stderr || 'mac-ocr ocr was aborted',
	{
		kind: 'abort',
		stderr,
	},
);

const isServiceInputDirectory = (directory: string): boolean => (
	path.dirname(directory) === os.tmpdir()
	&& serviceDirectoryPattern.test(path.basename(directory))
);

const isRecord = (value: unknown): value is Record<string, unknown> => (
	typeof value === 'object'
	&& value !== null
	&& !Array.isArray(value)
);

const isNativeHello = (value: unknown): value is NativeHello => (
	isRecord(value)
	&& value.type === 'hello'
	&& value.protocolVersion === protocolVersion
	&& typeof value.inputDirectory === 'string'
	&& isServiceInputDirectory(value.inputDirectory)
);

const isNativeError = (value: unknown): value is NativeError => (
	isRecord(value)
	&& (
		value.kind === 'usage'
		|| value.kind === 'unavailable'
		|| value.kind === 'runtime'
		|| value.kind === 'internal'
		|| value.kind === 'abort'
	)
	&& (value.code === undefined || typeof value.code === 'string')
	&& typeof value.message === 'string'
	&& (
		value.exitCode === undefined
		|| value.exitCode === null
		|| (typeof value.exitCode === 'number' && Number.isInteger(value.exitCode))
	)
	&& typeof value.stderr === 'string'
);

const isOcrResult = (value: unknown): value is OcrResult => (
	isRecord(value)
	&& typeof value.page === 'number'
	&& Number.isInteger(value.page)
	&& typeof value.pageCount === 'number'
	&& Number.isInteger(value.pageCount)
	&& typeof value.width === 'number'
	&& Number.isInteger(value.width)
	&& typeof value.height === 'number'
	&& Number.isInteger(value.height)
	&& typeof value.text === 'string'
	&& Array.isArray(value.observations)
);

const isNativeResponse = (value: unknown): value is NativeResponse => {
	if (
		!isRecord(value)
		|| typeof value.id !== 'number'
		|| !Number.isInteger(value.id)
		|| value.id < 0
		|| value.id > 4_294_967_295
	) {
		return false;
	}
	return (
		(value.type === 'result' && isOcrResult(value.result))
		|| (value.type === 'error' && isNativeError(value.error))
	);
};

const startService = (state: ServiceState): Promise<Service> => new Promise((_resolve, _reject) => {
	const subprocess = childProcess.spawn(binaryPath, [`--service=${protocolVersion}`], {
		stdio: ['pipe', 'pipe', 'pipe'],
	});
	if (serviceState === state) {
		state.startingPid = subprocess.pid;
	}
	let pending: PendingRequest | undefined;
	const stderrChunks: Buffer[] = [];
	let nextRequestId = 0;
	let stdout = Buffer.allocUnsafe(16 * 1024);
	let stdoutUsed = 0;
	let ready = false;
	let closed = false;
	let service: Service;
	const unrefIdleHandles = (): void => {
		subprocess.unref();
		(subprocess.stdin as typeof subprocess.stdin & { unref?: () => void }).unref?.();
		(subprocess.stdout as typeof subprocess.stdout & { unref?: () => void }).unref?.();
		(subprocess.stderr as typeof subprocess.stderr & { unref?: () => void }).unref?.();
	};

	const stderrText = (): string => Buffer.concat(stderrChunks).toString('utf8').trim();
	const rejectPending = (error: unknown): void => {
		if (!pending) {
			return;
		}
		if (pending.signal && pending.cancelAbortListener) {
			pending.signal.removeEventListener('abort', pending.cancelAbortListener);
		}
		pending.reject(error);
		pending = undefined;
		subprocess.unref();
	};
	const close = (error?: unknown, didFailToSpawn = false): void => {
		if (closed) {
			return;
		}
		closed = true;
		if (service?.inputDirectory) {
			removeServiceDirectory(service.inputDirectory);
		}
		const failure = didFailToSpawn
			? serviceSpawnFailure(error, stderrText())
			: serviceFailure('mac-ocr service stopped', stderrText(), error);
		rejectQueuedOcrRequests(failure);
		rejectPending(failure);
		if (!ready) {
			_reject(failure);
		}
		if (serviceState === state) {
			serviceState = undefined;
		}
	};
	const failProtocol = (message: string): void => {
		close(new Error(message));
		subprocess.kill();
	};
	const handleHello = (hello: NativeHello): void => {
		ready = true;
		service.inputDirectory = hello.inputDirectory;
		if (serviceState === state) {
			state.stopStarting = undefined;
			state.startingPid = undefined;
		}
		_resolve(service);
		queueMicrotask(() => {
			// Let the first Promise continuation submit work before handles unref.
			if (!pending) {
				unrefIdleHandles();
			}
		});
	};
	const handleResponse = (response: NativeResponse): void => {
		const request = pending;
		if (!request || request.id !== response.id) {
			failProtocol(`mac-ocr service returned unknown request ID ${response.id}`);
			return;
		}
		pending = undefined;
		if (request.signal && request.cancelAbortListener) {
			request.signal.removeEventListener('abort', request.cancelAbortListener);
		}
		subprocess.unref();
		if (request.signal?.aborted) {
			request.reject(serviceAbortFailure(response.type === 'error' ? response.error.stderr : ''));
			return;
		}
		if (response.type === 'result') {
			request.resolve(response.result);
			return;
		}
		request.reject(new MacOcrError(response.error.message, {
			kind: response.error.kind,
			code: response.error.code,
			exitCode: response.error.exitCode,
			stderr: response.error.stderr,
		}));
	};
	const handleFrame = (frame: Buffer): void => {
		let value: unknown;
		try {
			value = JSON.parse(frame.toString('utf8')) as unknown;
		} catch (error) {
			failProtocol(`mac-ocr service produced invalid JSON: ${error}`);
			return;
		}
		if (!ready) {
			if (!isNativeHello(value)) {
				failProtocol('mac-ocr service produced an invalid hello frame');
				return;
			}
			handleHello(value);
			return;
		}
		if (!isNativeResponse(value)) {
			failProtocol('mac-ocr service produced an invalid response frame');
			return;
		}
		handleResponse(value);
	};
	const readStdout = (chunk: Buffer): void => {
		const required = stdoutUsed + chunk.byteLength;
		if (required > stdout.byteLength) {
			const expanded = Buffer.allocUnsafe(Math.max(required, stdout.byteLength * 2));
			stdout.copy(expanded, 0, 0, stdoutUsed);
			stdout = expanded;
		}
		chunk.copy(stdout, stdoutUsed);
		stdoutUsed = required;
		let offset = 0;
		while (offset + 4 <= stdoutUsed) {
			const length = stdout.readUInt32LE(offset);
			if (length > maxFrameBytes) {
				failProtocol('mac-ocr service response exceeds the 64 MiB limit');
				return;
			}
			if (offset + 4 + length > stdoutUsed) {
				break;
			}
			offset += 4;
			handleFrame(stdout.subarray(offset, offset + length));
			offset += length;
			if (closed) {
				return;
			}
		}
		if (offset > 0) {
			stdout.copyWithin(0, offset, stdoutUsed);
			stdoutUsed -= offset;
		}
	};

	service = {
		pid: subprocess.pid!,
		inputDirectory: '',
		pendingRequests: () => (pending ? 1 : 0),
		request: (
			inputName,
			arguments_,
			password,
			signal,
		) => new Promise<OcrResult>((resolve, reject) => {
			if (closed) {
				reject(serviceFailure('mac-ocr service is not running', stderrText()));
				return;
			}
			if (signal?.aborted) {
				reject(serviceAbortFailure());
				return;
			}
			const id = nextRequestId;
			nextRequestId = nextRequestId === 4_294_967_295 ? 0 : nextRequestId + 1;
			if (pending) {
				reject(new MacOcrError(
					'mac-ocr service is already processing a request',
					{ kind: 'internal' },
				));
				return;
			}
			const frame = encodeFrame({
				id,
				command: 'ocr',
				inputName,
				arguments: arguments_,
				password,
			});
			let cancelAbortListener: (() => void) | undefined;
			if (signal) {
				cancelAbortListener = () => {
					if (pending?.id !== id) {
						return;
					}
					const cancelFrame = encodeFrame({
						id,
						command: 'cancel',
					});
					subprocess.stdin.write(cancelFrame, (error) => {
						if (error) {
							close(error);
						}
					});
				};
			}
			pending = {
				id,
				resolve,
				reject,
				signal,
				cancelAbortListener,
			};
			if (cancelAbortListener) {
				signal!.addEventListener('abort', cancelAbortListener, { once: true });
			}
			// The child alone keeps Node alive while this request is active.
			subprocess.ref();
			subprocess.stdin.write(frame, (error) => {
				if (error) {
					close(error);
				}
			});
		}),
		stop: () => {
			subprocess.stdin.destroy();
			subprocess.stdout.destroy();
			subprocess.kill();
			close();
		},
	};
	if (serviceState === state) {
		state.stopStarting = service.stop;
	}

	subprocess.stderr.on('data', (chunk: Buffer) => stderrChunks.push(chunk));
	subprocess.stdout.on('data', readStdout);
	subprocess.stdout.once('end', () => close());
	subprocess.stdin.once('error', close);
	subprocess.once('error', error => close(error, !ready));
	subprocess.once('close', () => close());
});

const ensureServiceIsRunning = (): Promise<Service> => {
	if (!serviceState) {
		const state: ServiceState = {};
		serviceState = state;
		state.promise = startService(state).then((service) => {
			if (serviceState === state) {
				state.active = service;
			}
			return service;
		}).catch((error) => {
			if (serviceState === state) {
				serviceState = undefined;
			}
			throw error;
		});
	}
	return serviceState.promise!;
};

const serviceInputFailure = (error: unknown): MacOcrError => {
	const detail = error instanceof Error ? error.message : String(error);
	return new MacOcrError(`mac-ocr service could not stage input: ${detail}`, {
		kind: 'runtime',
		cause: error,
	});
};

const removeInput = async (inputPath: string, suppressError: boolean): Promise<void> => {
	try {
		await fs.rm(inputPath, { force: true });
	} catch (error) {
		if (!suppressError) {
			throw serviceInputFailure(error);
		}
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
		const service = await ensureServiceIsRunning();
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
			await removeInput(inputPath, primaryError !== undefined);
		}
	}
};

const removeQueuedAbortListener = (request: QueuedOcrRequest): void => {
	if (request.signal && request.settleAbortListener) {
		request.signal.removeEventListener('abort', request.settleAbortListener);
	}
};

const rejectQueuedOcrRequests = (error: unknown): void => {
	for (const request of queuedOcrRequests.splice(0)) {
		removeQueuedAbortListener(request);
		request.reject(error);
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

export const shouldUseService = (): boolean => (
	serviceEnabled && isMainThread
);

export const stopService = (): void => {
	rejectQueuedOcrRequests(serviceFailure('mac-ocr service stopped', ''));
	const state = serviceState;
	serviceState = undefined;
	state?.stopStarting?.();
	state?.active?.stop();
};

export const disableServiceForTesting = (): void => {
	stopService();
	serviceEnabled = false;
};

export const servicePidForTesting = (): number | undefined => serviceState?.active?.pid;
export const startingServicePidForTesting = (): number | undefined => serviceState?.startingPid;
export const pendingServiceRequestsForTesting = (): number => (
	serviceState?.active?.pendingRequests() ?? 0
);
