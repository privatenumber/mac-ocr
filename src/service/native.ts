import childProcess from 'node:child_process';
import { addAbortListener } from 'node:events';
import fs from 'node:fs/promises';
import { MacOcrError } from '../errors.ts';
import { binaryPath } from '../process.ts';
import type { OcrResult } from '../types.ts';
import {
	serviceAbortFailure,
	serviceFailure,
	serviceSpawnFailure,
} from './failures.ts';
import {
	createFrameDecoder,
	encodeFrame,
	isNativeHello,
	isNativeResponse,
	type NativeHello,
	type NativeResponse,
} from './protocol.ts';

type PendingRequest = {
	id: number;
	resolve: (result: OcrResult) => void;
	reject: (error: unknown) => void;
	signal?: AbortSignal;
	abortSubscription?: ReturnType<typeof addAbortListener>;
	cancelGraceTimer?: NodeJS.Timeout;
};

export type NativeService = {
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
	promise?: Promise<NativeService>;
	active?: NativeService;
	stop?: () => void;
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
	// `close()` is the terminal transition: it settles active work and either
	// rejects or preserves queued work based on the active request's abort state.
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
	const detachPendingCancellation = (request: PendingRequest): void => {
		request.abortSubscription?.[Symbol.dispose]();
		request.abortSubscription = undefined;
		if (request.cancelGraceTimer) {
			clearTimeout(request.cancelGraceTimer);
			request.cancelGraceTimer = undefined;
		}
	};
	const rejectPending = (error: unknown): void => {
		if (!pending) {
			return;
		}
		const request = pending;
		pending = undefined;
		detachPendingCancellation(request);
		request.reject(error);
		subprocess.unref();
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
			// Swift owns normal cleanup; Node covers crashes before Swift's defer runs.
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
		if (rejectQueueOnClose && !pending?.signal?.aborted) {
			rejectQueuedRequests(failure);
		}
		rejectPending(pending?.signal?.aborted ? serviceAbortFailure(stderrText()) : failure);
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
	const handleHello = (hello: NativeHello): void => {
		ready = true;
		detachStartupAbortListener();
		service.inputDirectory = hello.inputDirectory;
		if (serviceState === state) {
			state.active = service;
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
	const handleResponse = (response: NativeResponse): boolean => {
		const request = pending;
		if (!request || request.id !== response.id) {
			failProtocol(`mac-ocr service returned unknown request ID ${response.id}`);
			return false;
		}
		pending = undefined;
		detachPendingCancellation(request);
		subprocess.unref();
		if (request.signal?.aborted) {
			request.reject(serviceAbortFailure(response.type === 'error' ? response.error.stderr : ''));
			return true;
		}
		if (response.type === 'result') {
			request.resolve(response.result);
			return true;
		}
		request.reject(new MacOcrError(response.error.message, {
			kind: response.error.kind,
			code: response.error.code,
			exitCode: response.error.exitCode,
			stderr: response.error.stderr,
		}));
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
			if (transportError) {
				reject(serviceFailure('mac-ocr service transport failed', stderrText(), transportError));
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
			pending = {
				id,
				resolve,
				reject,
				signal,
			};
			if (signal) {
				pending.abortSubscription = addAbortListener(signal, () => {
					const request = pending;
					if (request?.id !== id) {
						return;
					}
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
					const cancelFrame = encodeFrame({
						id,
						command: 'cancel',
					});
					subprocess.stdin.write(cancelFrame, (error) => {
						if (error) {
							recordTransportError(error);
						}
					});
				});
			}
			// The child alone keeps Node alive while this request is active.
			subprocess.ref();
			subprocess.stdin.write(frame, (error) => {
				if (error) {
					recordTransportError(error);
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

export const stopNativeService = (): void => {
	const state = serviceState;
	serviceState = undefined;
	state?.stop?.();
};

export const servicePidForTesting = (): number | undefined => serviceState?.active?.pid;
export const startingServicePidForTesting = (): number | undefined => serviceState?.startingPid;
export const pendingServiceRequestsForTesting = (): number => (
	serviceState?.active?.pendingRequests() ?? 0
);
