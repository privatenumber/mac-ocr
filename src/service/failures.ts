import { MacOcrError } from '../errors.ts';

export const serviceFailure = (
	message: string,
	stderr: string,
	cause?: unknown,
	exitCode?: number | null,
): MacOcrError => new MacOcrError(stderr || message, {
	kind: 'runtime',
	stderr,
	cause,
	exitCode,
});

export const serviceSpawnFailure = (error: unknown, stderr: string): MacOcrError => {
	const detail = error instanceof Error ? error.message : String(error);
	return new MacOcrError(`mac-ocr service failed to start: ${detail}`, {
		kind: 'spawn',
		stderr,
		cause: error,
	});
};

export const serviceAbortFailure = (stderr = ''): MacOcrError => new MacOcrError(
	stderr || 'mac-ocr operation was aborted',
	{
		kind: 'abort',
		stderr,
	},
);

export const serviceInputFailure = (error: unknown): MacOcrError => {
	const detail = error instanceof Error ? error.message : String(error);
	return new MacOcrError(`mac-ocr service could not stage input: ${detail}`, {
		kind: 'runtime',
		cause: error,
	});
};
