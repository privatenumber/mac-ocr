import type { OcrOptions, RegionOfInterest } from './types.ts';

const toTuple = (roi: Exclude<RegionOfInterest, string>): [number, number, number, number] => {
	if (Array.isArray(roi)) {
		if (roi.length !== 4) {
			throw new TypeError(`regionOfInterest tuple must have four values [x, y, width, height]; got ${roi.length}`);
		}
		return [roi[0], roi[1], roi[2], roi[3]];
	}
	const box = roi as { x: number;
		y: number;
		width: number;
		height: number; };
	return [box.x, box.y, box.width, box.height];
};

const requireUnit = (name: string, value: number): void => {
	if (!Number.isFinite(value) || value < 0 || value > 1) {
		throw new RangeError(`regionOfInterest.${name} must be a finite number in [0, 1]; got ${value}`);
	}
};

/**
 * Serialize a {@link RegionOfInterest} to the CLI's `x,y,w,h` string, validating
 * structured forms up front so callers get a clear TypeScript error instead of
 * a CLI usage failure. Bare strings pass through unchanged.
 */
export const serializeRegionOfInterest = (roi: RegionOfInterest): string => {
	if (typeof roi === 'string') {
		return roi;
	}
	if (roi === null || typeof roi !== 'object') {
		throw new TypeError(`regionOfInterest must be an object, tuple, or string; got ${typeof roi}`);
	}
	const [x, y, width, height] = toTuple(roi);
	requireUnit('x', x);
	requireUnit('y', y);
	requireUnit('width', width);
	requireUnit('height', height);
	if (width <= 0 || height <= 0) {
		throw new RangeError(`regionOfInterest width and height must be positive; got ${width}, ${height}`);
	}
	if (x + width > 1 || y + height > 1) {
		throw new RangeError(`regionOfInterest extends past the image (x+width=${x + width}, y+height=${y + height}); both must be <= 1`);
	}
	return `${x},${y},${width},${height}`;
};

/**
 * Map the shared + OCR options to CLI flags. `createSearchablePdf` simply
 * never sets `maxCandidates`. `password` is deliberately NOT mapped to
 * `--password` — argv is visible to every user on the machine via `ps`.
 * One-shot calls use `MAC_OCR_PDF_PASSWORD`; shared-service calls send the
 * password inside their framed stdin request.
 */
export const buildArgs = (options?: OcrOptions): string[] => {
	const args: string[] = [];
	if (options?.fast) {
		args.push('--fast');
	}
	if (options?.languages) {
		for (const language of options.languages) {
			args.push('--language', language);
		}
	}
	if (options?.confidence !== undefined) {
		args.push('--confidence', String(options.confidence));
	}
	if (options?.customWords) {
		for (const word of options.customWords) {
			args.push('--custom-words', word);
		}
	}
	if (options?.languageCorrection === false) {
		args.push('--no-language-correction');
	}
	if (options?.minTextHeight !== undefined) {
		args.push('--min-text-height', String(options.minTextHeight));
	}
	if (options?.maxCandidates !== undefined) {
		args.push('--max-candidates', String(options.maxCandidates));
	}
	if (options?.regionOfInterest !== undefined) {
		args.push('--roi', serializeRegionOfInterest(options.regionOfInterest));
	}
	if (options?.pdfDpi !== undefined) {
		args.push('--pdf-dpi', String(options.pdfDpi));
	}
	return args;
};
