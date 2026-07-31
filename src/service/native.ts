import childProcess from 'node:child_process';
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
	protocolVersion,
	type NativeHello,
	type NativeResponse,
} from './protocol.ts';

type PendingRequest = {
	id: number;
	resolve: (result: OcrResult) => void;
	reject: (error: unknown) => void;
	signal?: AbortSignal;
	cancelAbortListener?: () => void;
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
	stopStarting?: () => void;
	startingPid?: number;
};

type RejectQueuedRequests = (error: unknown) => void;

// Callback identity prevents a stopped service from clearing its replacement.
let serviceState: ServiceState | undefined;

const removeServiceDirectory = (directory: string): void => {
	// Swift owns normal cleanup; Node covers crashes before Swift's defer runs.
	fs.rm(directory, {
		recursive: true,
		force: true,
	}).catch(() => {});
};

const startNativeService = (
	state: ServiceState,
	rejectQueuedRequests: RejectQueuedRequests,
): Promise<NativeService> => new Promise((_resolve, _reject) => {
	const subprocess = childProcess.spawn(binaryPath, [`--service=${protocolVersion}`], {
		stdio: ['pipe', 'pipe', 'pipe'],
	});
	if (serviceState === state) {
		state.startingPid = subprocess.pid;
	}
	let pending: PendingRequest | undefined;
	const stderrChunks: Buffer[] = [];
	let nextRequestId = 0;
	let ready = false;
	let closed = false;
	let service: NativeService;
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
		rejectQueuedRequests(failure);
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
	const handleFrame = (frame: Buffer): boolean => {
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
		handleResponse(value);
		return !closed;
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
	subprocess.stdout.on('data', createFrameDecoder(handleFrame, failProtocol));
	subprocess.stdout.once('end', () => close());
	subprocess.stdin.once('error', close);
	subprocess.once('error', error => close(error, !ready));
	subprocess.once('close', () => close());
});

export const getNativeService = (
	rejectQueuedRequests: RejectQueuedRequests,
): Promise<NativeService> => {
	if (!serviceState) {
		const state: ServiceState = {};
		serviceState = state;
		state.promise = startNativeService(state, rejectQueuedRequests).then((service) => {
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

export const stopNativeService = (): void => {
	const state = serviceState;
	serviceState = undefined;
	state?.stopStarting?.();
	state?.active?.stop();
};

export const servicePidForTesting = (): number | undefined => serviceState?.active?.pid;
export const startingServicePidForTesting = (): number | undefined => serviceState?.startingPid;
export const pendingServiceRequestsForTesting = (): number => (
	serviceState?.active?.pendingRequests() ?? 0
);
