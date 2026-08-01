/** Category of failure from mac-ocr. */
export type MacOcrErrorKind =
	| 'usage' // bad arguments / unsupported input (exit 64)
	| 'unavailable' // a feature isn't available on this macOS version
	| 'runtime' // recognition or I/O failure
	| 'internal' // unexpected CLI failure
	| 'spawn' // the binary couldn't be started
	| 'parse' // the binary produced output we couldn't parse
	| 'abort'; // cancelled via an AbortSignal

/** Structured error envelope emitted by one-shot CLI calls on file descriptor 3. */
export type MacOcrErrorEnvelope = {
	schema: 'mac-ocr.error';
	schemaVersion: 1;
	kind: 'usage' | 'unavailable' | 'runtime' | 'internal';
	code: string;
	message: string;
	exitCode: number;
	command?: string;
	requires?: string;
};

type MacOcrErrorOptions = {
	kind: MacOcrErrorKind;

	/** Machine-readable error code (for example, `usage_error`), when available. */
	code?: string;

	/** Process exit code, or `null` when killed by a signal / never started. */
	exitCode?: number | null;

	/** Captured stderr from mac-ocr. */
	stderr?: string;
	cause?: unknown;
};

/**
 * A failure from the `mac-ocr` binary. Inspect `kind` to branch on the failure
 * category (e.g. `'usage'` for bad input, `'unavailable'` when a feature needs
 * a newer macOS), and `stderr` for the human-readable CLI message.
 */
export class MacOcrError extends Error {
	readonly kind: MacOcrErrorKind;

	readonly code?: string;

	readonly exitCode: number | null;

	readonly stderr: string;

	constructor(message: string, options: MacOcrErrorOptions) {
		super(message, { cause: options.cause });
		this.name = 'MacOcrError';
		this.kind = options.kind;
		this.code = options.code;
		this.exitCode = options.exitCode ?? null;
		this.stderr = options.stderr ?? '';
	}
}
