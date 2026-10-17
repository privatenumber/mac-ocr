import { createSearchablePdf } from '../../src/index.ts';
import type { Input, SearchablePdfOptions } from '../../src/types.ts';

// Compile-only contract: these calls must never start native work at runtime.
export const checkSignatures = (
	bytes: Input,
	options: SearchablePdfOptions,
	signal: AbortSignal,
) => {
	const pdf: Promise<Uint8Array> = createSearchablePdf(bytes, options);
	const file: Promise<void> = createSearchablePdf({
		inputPath: 'scan.pdf',
		outputPath: 'out.pdf',
		languages: ['en-US'],
		signal,
	});
	// @ts-expect-error File mode requires both paths.
	createSearchablePdf({ inputPath: 'scan.pdf' });
	// @ts-expect-error File mode requires an input path.
	createSearchablePdf({ outputPath: 'out.pdf' });
	createSearchablePdf({
		// @ts-expect-error File mode accepts no second argument.
		inputPath: 'scan.pdf',
		outputPath: 'out.pdf',
	}, options);
	// @ts-expect-error Byte input cannot route to a file.
	createSearchablePdf(bytes, { outputPath: 'out.pdf' });
	// @ts-expect-error Byte input cannot also specify an input file.
	createSearchablePdf(bytes, { inputPath: 'scan.pdf' });
	// @ts-expect-error Input paths are not byte inputs.
	createSearchablePdf('scan.pdf', options);
	return {
		pdf,
		file,
	};
};
