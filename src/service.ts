import childProcess from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { buildArgs } from './args.ts';
import { MacOcrError, type MacOcrErrorKind } from './errors.ts';
import { binaryPath, toBuffer } from './process.ts';
import type { Input, OcrOptions, OcrResult } from './types.ts';

const protocolVersion = 1;
const maxFrameBytes = 64 * 1024 * 1024;
const serviceDirectoryPattern = /^mac-ocr-service-\d+-[0-9A-Fa-f-]{36}$/;

const removeServiceDirectory = (directory: string): void => {
	fs.rm(directory, {
		recursive: true,
		force: true,
	}).catch(() => {});
};

type NativeHello = {
	type: 'hello';
	protocolVersion: number;
	binaryVersion: string;
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
	type: 'result' | 'error';
	result?: OcrResult;
	error?: NativeError;
};

type PendingRequest = {
	resolve: (result: OcrResult) => void;
	reject: (error: unknown) => void;
};

type Service = {
	pid: number;
	inputDirectory: string;
	pendingRequests: () => number;
	request: (inputName: string, arguments_: string[], password?: string) => Promise<OcrResult>;
	stop: () => void;
};

let serviceEnabled = true;
let serviceGeneration = 0;
let servicePromise: Promise<Service> | undefined;
let activeService: Service | undefined;
let stopStartingService: (() => void) | undefined;
let startingServicePid: number | undefined;

const encodeFrame = (value: unknown): Buffer => {
	const payload = Buffer.from(JSON.stringify(value), 'utf8');
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

const isServiceInputDirectory = (directory: string): boolean => (
	path.dirname(directory) === os.tmpdir()
	&& serviceDirectoryPattern.test(path.basename(directory))
);

const startService = (generation: number): Promise<Service> => new Promise((_resolve, _reject) => {
	const subprocess = childProcess.spawn(binaryPath, [`--service=${protocolVersion}`], {
		stdio: ['pipe', 'pipe', 'pipe'],
	});
	if (generation === serviceGeneration) {
		startingServicePid = subprocess.pid;
	}
	const pending = new Map<number, PendingRequest>();
	const stderrChunks: Buffer[] = [];
	let nextRequestId = 0;
	let stdout = Buffer.allocUnsafe(16 * 1024);
	let stdoutUsed = 0;
	let ready = false;
	let closed = false;
	let referenceCount = 0;
	let service: Service;
	const unrefIdleHandles = (): void => {
		subprocess.unref();
		(subprocess.stdin as typeof subprocess.stdin & { unref?: () => void }).unref?.();
		(subprocess.stdout as typeof subprocess.stdout & { unref?: () => void }).unref?.();
		(subprocess.stderr as typeof subprocess.stderr & { unref?: () => void }).unref?.();
	};

	const stderrText = (): string => Buffer.concat(stderrChunks).toString('utf8').trim();
	const unref = (): void => {
		if (referenceCount > 0) {
			referenceCount -= 1;
			if (referenceCount === 0) {
				subprocess.unref();
			}
		}
	};
	const rejectPending = (error: unknown): void => {
		for (const request of pending.values()) {
			request.reject(error);
			unref();
		}
		pending.clear();
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
		rejectPending(failure);
		if (!ready) {
			_reject(failure);
		}
		if (generation === serviceGeneration) {
			activeService = undefined;
			servicePromise = undefined;
			stopStartingService = undefined;
			startingServicePid = undefined;
		}
	};
	const failProtocol = (message: string): void => {
		close(new Error(message));
		subprocess.kill();
	};
	const handleHello = (hello: NativeHello): void => {
		if (
			hello.type !== 'hello'
			|| hello.protocolVersion !== protocolVersion
			|| !isServiceInputDirectory(hello.inputDirectory)
		) {
			failProtocol('mac-ocr service protocol version mismatch');
			return;
		}
		ready = true;
		service.inputDirectory = hello.inputDirectory;
		if (generation === serviceGeneration) {
			stopStartingService = undefined;
			startingServicePid = undefined;
		}
		_resolve(service);
		queueMicrotask(() => {
			if (referenceCount === 0) {
				unrefIdleHandles();
			}
		});
	};
	const handleResponse = (response: NativeResponse): void => {
		const request = pending.get(response.id);
		if (!request) {
			failProtocol(`mac-ocr service returned unknown request ID ${response.id}`);
			return;
		}
		pending.delete(response.id);
		unref();
		if (response.type === 'result' && response.result) {
			request.resolve(response.result);
			return;
		}
		if (response.type === 'error' && response.error) {
			request.reject(new MacOcrError(response.error.message, {
				kind: response.error.kind,
				code: response.error.code,
				exitCode: response.error.exitCode,
				stderr: response.error.stderr || stderrText(),
			}));
			return;
		}
		request.reject(serviceFailure('mac-ocr service returned an invalid response', stderrText()));
	};
	const handleFrame = (frame: Buffer): void => {
		let value: NativeHello | NativeResponse;
		try {
			value = JSON.parse(frame.toString('utf8')) as NativeHello | NativeResponse;
		} catch (error) {
			failProtocol(`mac-ocr service produced invalid JSON: ${error}`);
			return;
		}
		if (!ready) {
			handleHello(value as NativeHello);
			return;
		}
		handleResponse(value as NativeResponse);
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
		pendingRequests: () => pending.size,
		request: (inputName, arguments_, password) => new Promise<OcrResult>((resolve, reject) => {
			if (closed) {
				reject(serviceFailure('mac-ocr service is not running', stderrText()));
				return;
			}
			const id = nextRequestId;
			nextRequestId = nextRequestId === 4_294_967_295 ? 0 : nextRequestId + 1;
			if (pending.has(id)) {
				reject(new MacOcrError(
					'mac-ocr service request ID space exhausted',
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
			pending.set(id, {
				resolve,
				reject,
			});
			if (referenceCount === 0) {
				subprocess.ref();
			}
			referenceCount += 1;
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
	if (generation === serviceGeneration) {
		stopStartingService = service.stop;
	}

	subprocess.stderr.on('data', (chunk: Buffer) => stderrChunks.push(chunk));
	subprocess.stdout.on('data', readStdout);
	subprocess.stdout.once('end', () => close());
	subprocess.stdin.once('error', close);
	subprocess.once('error', error => close(error, !ready));
	subprocess.once('close', () => close());
});

const ensureServiceIsRunning = (): Promise<Service> => {
	if (!servicePromise) {
		serviceGeneration += 1;
		const generation = serviceGeneration;
		servicePromise = startService(generation).then((service) => {
			if (generation === serviceGeneration) {
				activeService = service;
			}
			return service;
		}).catch((error) => {
			if (generation === serviceGeneration) {
				activeService = undefined;
				servicePromise = undefined;
			}
			throw error;
		});
	}
	return servicePromise;
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

export const ocrWithService = async (input: Input, options?: OcrOptions): Promise<OcrResult> => {
	const buffer = toBuffer(input);
	let inputPath: string | undefined;
	let primaryError: unknown;
	try {
		const service = await ensureServiceIsRunning();
		const inputName = crypto.randomUUID();
		inputPath = path.join(service.inputDirectory, inputName);
		try {
			await fs.writeFile(inputPath, buffer, {
				flag: 'wx',
				mode: 0o600,
			});
		} catch (error) {
			throw serviceInputFailure(error);
		}
		const arguments_ = buildArgs(options);
		const password = options?.password || process.env.MAC_OCR_PDF_PASSWORD;
		return await service.request(inputName, arguments_, password);
	} catch (error) {
		primaryError = error;
		throw error;
	} finally {
		if (inputPath) {
			await removeInput(inputPath, primaryError !== undefined);
		}
	}
};

export const shouldUseService = (options?: OcrOptions): boolean => (
	serviceEnabled && !options?.signal
);

export const stopService = (): void => {
	serviceGeneration += 1;
	stopStartingService?.();
	stopStartingService = undefined;
	startingServicePid = undefined;
	activeService?.stop();
	activeService = undefined;
	servicePromise = undefined;
};

export const disableServiceForTesting = (): void => {
	stopService();
	serviceEnabled = false;
};

export const servicePidForTesting = (): number | undefined => activeService?.pid;
export const startingServicePidForTesting = (): number | undefined => startingServicePid;
export const pendingServiceRequestsForTesting = (): number => activeService?.pendingRequests() ?? 0;
