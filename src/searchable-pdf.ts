import { buildArgs } from './args.ts';
import { collectStdout, spawnBinary } from './process.ts';
import type { Input, SearchablePdfOptions } from './types.ts';

/**
 * Produce a searchable PDF from image or PDF bytes — the same content with an
 * invisible, selectable OCR text layer added. Returns the PDF bytes.
 *
 * ```ts
 * const pdf = await createSearchablePdf(await fs.readFile('scan.pdf'))
 * await fs.writeFile('scan.ocr.pdf', pdf)
 * ```
 */
export const createSearchablePdf = async (
	input: Input,
	options?: SearchablePdfOptions,
): Promise<Uint8Array> => {
	const args = ['searchable-pdf', ...buildArgs(options)];
	if (options?.ocrAllPages) {
		args.push('--ocr-all-pages');
	}
	if (options?.imageQuality !== undefined) {
		args.push('--image-quality', String(options.imageQuality));
	}
	args.push('-o', '-', '-');
	const stdout = await collectStdout(
		spawnBinary(args, {
			input,
			signal: options?.signal,
			password: options?.password,
		}),
		'mac-ocr searchable-pdf',
	);
	return stdout;
};
