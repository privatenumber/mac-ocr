import childProcess from 'node:child_process';
import { addAbortListener } from 'node:events';
import fs from 'node:fs/promises';
import { MacOcrError } from '../errors.ts';
import { binaryPath } from '../process.ts';
import type { OcrResult } from '../types.ts';
import {
	createFrameDecoder,
	encodeFrame,
	isLanguageList,
	isNativeArtifact,
	isNativeHello,
	isNativeResponse,
	isOcrResult,
	type NativeResponse,
} from './protocol.ts';
import {
	serviceAbortFailure,
	serviceFailure,
	serviceSpawnFailure,
} from './failures.ts';

export type NativeOperation = 'ocr' | 'ocr-pages' | 'searchable-pdf' | 'languages';

export type NativeRequest = {
	operation: NativeOperation;
	inputName?: string;
	arguments?: string[];
	password?: string;
	outputName?: string;
};

export type NativeStream = AsyncIterable<OcrResult> & {
	cancel: () => Promise<void>;
	done: Promise<void>;
};

type PendingBase = {
	id: number;
	operation: NativeOperation;
	abortSubscription?: ReturnType<typeof addAbortListener>;
	cancelGraceTimer?: NodeJS.Timeout;
	cancelled: boolean;
};

type PendingUnary = PendingBase & {
	type: 'unary';
	resolve: (result: unknown) => void;
	reject: (error: unknown) => void;
};

type PendingStream = PendingBase & {
	type: 'stream';
	nextSequence: number;
	next?: PromiseWithResolvers<IteratorResult<OcrResult>>;
	completed: boolean;
	error?: unknown;
	resolveDone: () => void;
	done: Promise<void>;
};

type PendingRequest = PendingUnary | PendingStream;

export type NativeService = {
	pid: number;
	inputDirectory: string;
	pendingRequests: () => number;
	request: (request: NativeRequest, signal?: AbortSignal) => Promise<unknown>;
	stream: (request: NativeRequest, signal?: AbortSignal) => NativeStream;
	stop: (preserveQueuedRequests?: boolean) => void;
};

type ServiceState = {
	promise?: Promise<NativeService>;
	active?: NativeService;
	stop?: (preserveQueuedRequests?: boolean) => void;
	startingPid?: number;
};

type RejectQueuedRequests = (error: unknown) => void;

type ExitStatus = {
	code: number | null;
	signal: NodeJS.Signals | null;
};

const transportCloseGraceMilliseconds = 5000;
const cancellationGraceMilliseconds = 5000;
const maxRetainedStderrBytes = 64 * 1024;

// Callback identity prevents a stopped service from clearing its replacement.
let serviceState: ServiceState | undefined;

const responseError = (response: Extract<NativeResponse, { type: 'error' }>): MacOcrError => new MacOcrError(
	response.error.message,
	{
		kind: response.error.kind,
		code: response.error.code,
		exitCode: response.error.exitCode,
		stderr: response.error.stderr,
	},
);

const isResultForOperation = (operation: NativeOperation, result: unknown): boolean => {
	if (operation === 'ocr') {
		return isOcrResult(result);
	}
	if (operation === 'searchable-pdf') {
		return isNativeArtifact(result);
	}
	return operation === 'languages' && isLanguageList(result);
};

const startNativeService = (
	state: ServiceState,
	rejectQueuedRequests: RejectQueuedRequests,
	startupSignal?: AbortSignal,
): Promise<NativeService> => new Promise((_resolve, _reject) => {
	const subprocess = childProcess.spawn(binaryPath, ['--service'], {
		stdio: ['pipe', 'pipe', 'pipe'],
	});
	if (serviceState === state) {
		state.startingPid = subprocess.pid;
	}
	let pending: PendingRequest | undefined;
	let retainedStderr = Buffer.alloc(0);
	let nextRequestId = 0;
	let ready = false;
	let closed = false;
	let protocolFailed = false;
	let rejectQueueOnClose = true;
	let failureOverride: MacOcrError | undefined;
	let transportError: unknown;
	let forceExitTimer: NodeJS.Timeout | undefined;
	let startupAbortSubscription: ReturnType<typeof addAbortListener> | undefined;
	let service: NativeService;
	const unrefIdleHandles = (): void => {
		subprocess.unref();
		(subprocess.stdin as typeof subprocess.stdin & { unref?: () => void }).unref?.();
		(subprocess.stdout as typeof subprocess.stdout & { unref?: () => void }).unref?.();
		(subprocess.stderr as typeof subprocess.stderr & { unref?: () => void }).unref?.();
	};
	const stderrText = (): string => retainedStderr.toString('utf8').trim();
	const retainStderr = (chunk: Buffer): void => {
		const retainedBytes = Math.min(
			maxRetainedStderrBytes,
			retainedStderr.byteLength + chunk.byteLength,
		);
		const nextStderr = Buffer.allocUnsafe(retainedBytes);
		const chunkBytes = Math.min(chunk.byteLength, retainedBytes);
		const previousBytes = retainedBytes - chunkBytes;
		retainedStderr.copy(nextStderr, 0, retainedStderr.byteLength - previousBytes);
		chunk.copy(nextStderr, previousBytes, chunk.byteLength - chunkBytes);
		retainedStderr = nextStderr;
	};
	const detachStartupAbortListener = (): void => {
		startupAbortSubscription?.[Symbol.dispose]();
		startupAbortSubscription = undefined;
	};
	const detachPendingCancellation = (request: PendingRequest): void => {
		request.abortSubscription?.[Symbol.dispose]();
		request.abortSubscription = undefined;
		if (request.cancelGraceTimer) {
			clearTimeout(request.cancelGraceTimer);
			request.cancelGraceTimer = undefined;
		}
	};
	const recordTransportError = (error: unknown): void => {
		if (closed) {
			return;
		}
		transportError ??= error;
		if (!forceExitTimer) {
			forceExitTimer = setTimeout(() => subprocess.kill('SIGKILL'), transportCloseGraceMilliseconds);
			forceExitTimer.unref();
		}
	};
	const write = (value: unknown): void => {
		subprocess.stdin.write(encodeFrame(value), (error) => {
			if (error) {
				recordTransportError(error);
			}
		});
	};
	const settleStream = (request: PendingStream, error?: unknown): void => {
		if (pending === request) {
			pending = undefined;
		}
		detachPendingCancellation(request);
		subprocess.unref();
		const terminalError = request.cancelled
			? serviceAbortFailure(error instanceof MacOcrError ? error.stderr : stderrText())
			: error;
		request.completed = true;
		request.error = terminalError;
		if (request.next) {
			const { next } = request;
			request.next = undefined;
			if (terminalError === undefined) {
				next.resolve({
					done: true,
					value: undefined,
				});
			} else {
				next.reject(terminalError);
			}
		}
		request.resolveDone();
	};
	const settleUnary = (request: PendingUnary, error?: unknown, result?: unknown): void => {
		if (pending === request) {
			pending = undefined;
		}
		detachPendingCancellation(request);
		subprocess.unref();
		if (request.cancelled) {
			request.reject(serviceAbortFailure(
				error instanceof MacOcrError ? error.stderr : stderrText(),
			));
		} else if (error === undefined) {
			request.resolve(result);
		} else {
			request.reject(error);
		}
	};
	const settlePending = (error: unknown): void => {
		if (!pending) {
			return;
		}
		if (pending.type === 'stream') {
			settleStream(pending, pending.cancelled ? serviceAbortFailure(stderrText()) : error);
			return;
		}
		settleUnary(pending, pending.cancelled ? serviceAbortFailure(stderrText()) : error);
	};
	const cancelPending = (request: PendingRequest): void => {
		if (pending !== request || request.cancelGraceTimer) {
			return;
		}
		request.cancelled = true;
		request.cancelGraceTimer = setTimeout(() => {
			if (pending !== request) {
				return;
			}
			subprocess.stdin.destroy();
			subprocess.stdout.destroy();
			subprocess.stderr.destroy();
			subprocess.kill('SIGKILL');
			close();
		}, cancellationGraceMilliseconds);
		request.cancelGraceTimer.unref();
		try {
			write({
				id: request.id,
				command: 'cancel',
			});
		} catch (error) {
			recordTransportError(error);
		}
	};
	const close = (
		error?: unknown,
		didFailToSpawn = false,
		exitStatus?: ExitStatus,
	): void => {
		if (closed) {
			return;
		}
		closed = true;
		detachStartupAbortListener();
		if (forceExitTimer) {
			clearTimeout(forceExitTimer);
			forceExitTimer = undefined;
		}
		if (service?.inputDirectory) {
			fs.rm(service.inputDirectory, {
				recursive: true,
				force: true,
			}).catch(() => {});
		}
		let message = 'mac-ocr service stopped';
		let exitCode: number | null | undefined;
		if (exitStatus?.signal) {
			message = `mac-ocr service was killed by ${exitStatus.signal}`;
			exitCode = null;
		} else if (exitStatus?.code !== null && exitStatus?.code !== undefined) {
			message = `mac-ocr service exited with code ${exitStatus.code}`;
			exitCode = exitStatus.code;
		}
		const failure = failureOverride ?? (didFailToSpawn
			? serviceSpawnFailure(error, stderrText())
			: serviceFailure(message, stderrText(), error ?? transportError, exitCode));
		if (rejectQueueOnClose && !pending?.cancelled) {
			rejectQueuedRequests(failure);
		}
		settlePending(failure);
		if (!ready) {
			_reject(failure);
		}
		if (serviceState === state) {
			serviceState = undefined;
		}
	};
	const failProtocol = (message: string): void => {
		if (protocolFailed) {
			return;
		}
		protocolFailed = true;
		const error = new Error(message);
		failureOverride = serviceFailure(message, stderrText(), error);
		subprocess.kill('SIGKILL');
	};
	const handleHello = (hello: { inputDirectory: string }): void => {
		ready = true;
		detachStartupAbortListener();
		service.inputDirectory = hello.inputDirectory;
		if (serviceState === state) {
			state.active = service;
			state.startingPid = undefined;
		}
		_resolve(service);
		queueMicrotask(() => {
			if (!pending) {
				unrefIdleHandles();
			}
		});
	};
	const handleResponse = (response: NativeResponse): boolean => {
		const request = pending;
		if (!request || request.id !== response.id) {
			failProtocol(`mac-ocr service returned unknown request ID ${response.id}`);
			return false;
		}
		if (response.type === 'error') {
			const error = responseError(response);
			if (request.type === 'stream') {
				settleStream(request, request.cancelled ? serviceAbortFailure(error.stderr) : error);
			} else {
				settleUnary(request, error);
			}
			return true;
		}
		if (response.type === 'item') {
			if (request.type === 'stream' && request.cancelled) {
				return true;
			}
			if (
				request.type !== 'stream'
				|| response.sequence !== request.nextSequence
				|| !isOcrResult(response.result)
				|| !request.next
			) {
				failProtocol(`mac-ocr service returned an invalid stream item for request ${response.id}`);
				return false;
			}
			request.nextSequence += 1;
			const { next } = request;
			request.next = undefined;
			next.resolve({
				done: false,
				value: response.result,
			});
			return true;
		}
		if (request.type === 'stream') {
			if (response.result !== undefined && response.result !== null) {
				failProtocol(`mac-ocr service completed stream request ${response.id} with a result`);
				return false;
			}
			settleStream(request);
			return true;
		}
		if (!isResultForOperation(request.operation, response.result)) {
			failProtocol(`mac-ocr service returned an invalid result for request ${response.id}`);
			return false;
		}
		settleUnary(request, undefined, response.result);
		return true;
	};
	const handleFrame = (frame: Buffer): boolean => {
		if (protocolFailed) {
			return false;
		}
		let value: unknown;
		try {
			value = JSON.parse(frame.toString('utf8')) as unknown;
		} catch (error) {
			failProtocol(`mac-ocr service produced invalid JSON: ${error}`);
			return false;
		}
		if (!ready) {
			if (!isNativeHello(value)) {
				failProtocol('mac-ocr service produced an invalid hello frame');
				return false;
			}
			handleHello(value);
			return !closed;
		}
		if (!isNativeResponse(value)) {
			failProtocol('mac-ocr service produced an invalid response frame');
			return false;
		}
		return handleResponse(value) && !closed;
	};
	const requestId = (): number => {
		const id = nextRequestId;
		nextRequestId = nextRequestId === 4_294_967_295 ? 0 : nextRequestId + 1;
		return id;
	};
	const submit = (
		request: NativeRequest,
		signal: AbortSignal | undefined,
		pendingRequest: PendingRequest,
	): void => {
		pending = pendingRequest;
		if (closed) {
			settlePending(serviceFailure('mac-ocr service is not running', stderrText()));
			return;
		}
		if (transportError) {
			settlePending(serviceFailure('mac-ocr service transport failed', stderrText(), transportError));
			return;
		}
		if (signal?.aborted) {
			settlePending(serviceAbortFailure());
			return;
		}
		if (signal) {
			pendingRequest.abortSubscription = addAbortListener(
				signal,
				() => cancelPending(pendingRequest),
			);
		}
		subprocess.ref();
		try {
			write({
				id: pendingRequest.id,
				operation: request.operation,
				inputName: request.inputName,
				arguments: request.arguments,
				password: request.password,
				outputName: request.outputName,
			});
		} catch (error) {
			settlePending(error);
		}
	};
	service = {
		pid: subprocess.pid!,
		inputDirectory: '',
		pendingRequests: () => (pending ? 1 : 0),
		request: (request, signal) => {
			const { promise, resolve, reject } = Promise.withResolvers<unknown>();
			if (pending) {
				reject(new MacOcrError('mac-ocr service is already processing a request', { kind: 'internal' }));
				return promise;
			}
			const id = requestId();
			submit(request, signal, {
				id,
				operation: request.operation,
				type: 'unary',
				resolve,
				reject,
				cancelled: false,
			});
			return promise;
		},
		stream: (request, signal) => {
			const { promise: done, resolve: resolveDone } = Promise.withResolvers<void>();
			const stream: PendingStream = {
				id: requestId(),
				operation: request.operation,
				type: 'stream',
				nextSequence: 0,
				completed: false,
				resolveDone,
				done,
				cancelled: false,
			};
			if (pending) {
				stream.completed = true;
				stream.error = new MacOcrError('mac-ocr service is already processing a request', { kind: 'internal' });
				stream.resolveDone();
			} else {
				submit(request, signal, stream);
			}
			const next = (): Promise<IteratorResult<OcrResult>> => {
				if (stream.completed) {
					return stream.error === undefined
						? Promise.resolve({
							done: true,
							value: undefined,
						})
						: Promise.reject(stream.error);
				}
				if (stream.next) {
					return Promise.reject(new MacOcrError('mac-ocr stream already has a pending next() call', { kind: 'internal' }));
				}
				stream.next = Promise.withResolvers<IteratorResult<OcrResult>>();
				write({
					id: stream.id,
					command: 'pull',
				});
				return stream.next.promise;
			};
			return {
				[Symbol.asyncIterator]: () => ({ next }),
				next,
				cancel: async () => {
					cancelPending(stream);
					await stream.done;
				},
				done,
			};
		},
		stop: (preserveQueuedRequests = false) => {
			if (preserveQueuedRequests) {
				rejectQueueOnClose = false;
			}
			subprocess.stdin.destroy();
			subprocess.stdout.destroy();
			subprocess.kill();
			close();
		},
	};
	if (serviceState === state) {
		state.stop = service.stop;
	}
	if (startupSignal) {
		startupAbortSubscription = addAbortListener(startupSignal, () => {
			if (ready || closed) {
				return;
			}
			rejectQueueOnClose = false;
			failureOverride = serviceAbortFailure();
			subprocess.stdin.destroy();
			subprocess.stdout.destroy();
			subprocess.stderr.destroy();
			subprocess.kill('SIGKILL');
			subprocess.unref();
			close();
		});
	}

	subprocess.stderr.on('data', retainStderr);
	subprocess.stdout.on('data', createFrameDecoder(handleFrame, failProtocol));
	subprocess.stdin.once('error', recordTransportError);
	subprocess.once('error', error => close(error, !ready));
	subprocess.once('close', (code, signalName) => close(undefined, false, {
		code,
		signal: signalName,
	}));
});

export const getNativeService = (
	rejectQueuedRequests: RejectQueuedRequests,
	signal?: AbortSignal,
): Promise<NativeService> => {
	if (!serviceState) {
		const state: ServiceState = {};
		serviceState = state;
		state.promise = startNativeService(state, rejectQueuedRequests, signal).catch((error) => {
			if (serviceState === state) {
				serviceState = undefined;
			}
			throw error;
		});
	}
	return serviceState.promise!;
};

export const stopNativeService = (preserveQueuedRequests = false): void => {
	const state = serviceState;
	serviceState = undefined;
	state?.stop?.(preserveQueuedRequests);
};

export const servicePidForTesting = (): number | undefined => serviceState?.active?.pid;
export const startingServicePidForTesting = (): number | undefined => serviceState?.startingPid;
export const pendingServiceRequestsForTesting = (): number => (
	serviceState?.active?.pendingRequests() ?? 0
);
