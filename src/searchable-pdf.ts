import { buildArgs } from './args.ts';
import { collectStdout, spawnBinary } from './process.ts';
import type { Input, SearchablePdfOptions } from './types.ts';

const flagArgument = (flag: string, enabled?: boolean): string[] => (
	enabled ? [flag] : []
);

const valueArgument = (flag: string, value?: number | string): string[] => (
	value === undefined ? [] : [flag, String(value)]
);

const buildSearchablePdfArgs = (options?: SearchablePdfOptions): string[] => [
	'searchable-pdf',
	...buildArgs(options),
	...flagArgument('--ocr-all-pages', options?.ocrAllPages),
	...valueArgument('--image-quality', options?.imageQuality),
	...valueArgument('--image-page-dpi', options?.imagePageDpi),
	...valueArgument('--image-downsample-dpi', options?.imageDownsampleDpi),
	...valueArgument('--ocr-strategy', options?.ocrStrategy),
	'-o',
	'-',
	'-',
];

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
	const stdout = await collectStdout(
		spawnBinary(buildSearchablePdfArgs(options), {
			input,
			signal: options?.signal,
			password: options?.password,
		}),
		'mac-ocr searchable-pdf',
	);
	return stdout;
};
