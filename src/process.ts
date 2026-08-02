import childProcess, { type ChildProcessWithoutNullStreams } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { MacOcrError, type MacOcrErrorEnvelope, type MacOcrErrorKind } from './errors.ts';
import type { Input } from './types.ts';

/**
 * The prebuilt CLI binary shipped in this package. Tests run against it too:
 * `pnpm test:node` copies a debug build to `bin/mac-ocr` (gitignored;
 * `prepack` always rebuilds the universal release binary before publish).
 */
export const binaryPath = fileURLToPath(new URL('../bin/mac-ocr', import.meta.url));

export const toBuffer = (input: Input): Buffer => {
	if (Buffer.isBuffer(input)) {
		return input;
	}
	if (input instanceof ArrayBuffer) {
		return Buffer.from(input);
	}
	if (input instanceof Uint8Array) {
		return Buffer.from(input.buffer, input.byteOffset, input.byteLength);
	}
	throw new TypeError('Input must be a Buffer, Uint8Array, or ArrayBuffer of image/PDF bytes.');
};

export type Spawned = {
	proc: ChildProcessWithoutNullStreams;
	exit: Promise<ExitStatus>;

	/** The caller's AbortSignal, used to tell cancellation apart from crashes. */
	signal?: AbortSignal;
	stderrChunks: Buffer[];
	machineErrorChunks: Buffer[];
};

type ExitStatus = {
	code: number | null;
	signal: NodeJS.Signals | null;
};

type SpawnOptions = {
	input?: Input;
	signal?: AbortSignal;

	/**
	 * PDF password, passed via the `MAC_OCR_PDF_PASSWORD` env var rather than
	 * `--password` so it never appears in the process list (`argv` is visible
	 * to every user on the machine; the env is not).
	 */
	password?: string;
};

/**
 * Spawn the binary with stdout, stderr, and an extra fd 3 for the machine-error
 * envelope. Listeners are attached synchronously so a failed spawn (ENOENT)
 * surfaces on `exit` rather than crashing the host. Bytes, when provided, are
 * written to stdin.
 */
export const spawnBinary = (
	args: string[],
	options: SpawnOptions = {},
): Spawned => {
	// Convert (and validate) the input BEFORE spawning, so a bad input throws
	// without orphaning a started process that would wait on stdin forever.
	const stdin = options.input === undefined ? undefined : toBuffer(options.input);

	const proc = childProcess.spawn(binaryPath, args, {
		env: {
			...process.env,
			MAC_OCR_ERROR_FORMAT: 'json',
			// The CLI treats an empty password as unset, so only forward
			// non-empty values; an ambient MAC_OCR_PDF_PASSWORD still flows
			// through process.env above (the documented fallback).
			...(options.password ? { MAC_OCR_PDF_PASSWORD: options.password } : undefined),
		},
		signal: options.signal,
		stdio: ['pipe', 'pipe', 'pipe', 'pipe'],
	}) as ChildProcessWithoutNullStreams;

	const stderrChunks: Buffer[] = [];
	const machineErrorChunks: Buffer[] = [];
	proc.stderr.on('data', (chunk: Buffer) => stderrChunks.push(chunk));
	proc.stdio[3]?.on('data', (chunk: Buffer) => machineErrorChunks.push(chunk));

	const exit = once(proc, 'close').then(([code, signalName]) => ({
		code: code as number | null,
		signal: signalName as NodeJS.Signals | null,
	}));
	exit.catch(() => {});

	// A child that exits before reading all of stdin makes the write end EPIPE;
	// the real cause already lands on `exit`, so swallow it here.
	proc.stdin.on('error', () => {});
	if (stdin === undefined) {
		proc.stdin.end();
	} else {
		proc.stdin.end(stdin);
	}

	return {
		proc,
		exit,
		signal: options.signal,
		stderrChunks,
		machineErrorChunks,
	};
};

const stderrText = (spawned: Spawned): string => Buffer.concat(spawned.stderrChunks).toString('utf8').trim();

const isAbortError = (error: unknown): boolean => (
	error instanceof Error && (error.name === 'AbortError' || /abort/i.test(error.message))
);

const parseErrorEnvelope = (spawned: Spawned): MacOcrErrorEnvelope | undefined => {
	const text = Buffer.concat(spawned.machineErrorChunks).toString('utf8').trim();
	if (!text) {
		return undefined;
	}
	const lastLine = text.split('\n').findLast(Boolean);
	if (!lastLine) {
		return undefined;
	}
	try {
		const envelope = JSON.parse(lastLine) as MacOcrErrorEnvelope;
		if (envelope?.schema === 'mac-ocr.error' && envelope.schemaVersion === 1) {
			return envelope;
		}
	} catch {}
	return undefined;
};

/** Resolve once the process exits cleanly, or throw a typed {@link MacOcrError}. */
export const waitForExit = async (spawned: Spawned, label: string): Promise<void> => {
	let result: ExitStatus;
	try {
		result = await spawned.exit;
	} catch (error) {
		if (spawned.signal?.aborted || isAbortError(error)) {
			throw new MacOcrError(`${label} was aborted`, {
				kind: 'abort',
				stderr: stderrText(spawned),
				cause: error,
			});
		}
		const detail = error instanceof Error ? error.message : String(error);
		throw new MacOcrError(`${label} failed to start: ${detail}`, {
			kind: 'spawn',
			stderr: stderrText(spawned),
			cause: error,
		});
	}

	if (result.signal !== null) {
		const stderr = stderrText(spawned);
		// `abort` is reserved for the caller's own cancellation. Any other
		// signal death (external SIGKILL, a crash) is a runtime failure and
		// must not masquerade as one.
		if (spawned.signal?.aborted) {
			throw new MacOcrError(stderr || `${label} was aborted`, {
				kind: 'abort',
				stderr,
			});
		}
		throw new MacOcrError(stderr || `${label} was killed by ${result.signal}`, {
			kind: 'runtime',
			stderr,
		});
	}

	if (result.code !== 0) {
		const stderr = stderrText(spawned);
		const envelope = parseErrorEnvelope(spawned);
		const kind: MacOcrErrorKind = envelope?.kind ?? (result.code === 64 ? 'usage' : 'runtime');
		// The CLI's stderr is the most specific message; strip its "Error: "
		// prefix so the thrown Error doesn't read "Error: Error: ...".
		const message = stderr.replace(/^Error:\s*/, '')
			|| envelope?.message
			|| `${label} exited with code ${result.code}`;
		throw new MacOcrError(message, {
			kind,
			code: envelope?.code,
			exitCode: result.code,
			stderr,
		});
	}
};

/** Collect stdout to completion, throwing a typed error on a non-zero exit. */
export const collectStdout = async (spawned: Spawned, label: string): Promise<Buffer> => {
	const chunks: Buffer[] = [];
	spawned.proc.stdout.on('data', (chunk: Buffer) => chunks.push(chunk));
	await waitForExit(spawned, label);
	return Buffer.concat(chunks);
};
