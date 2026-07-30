import { describe } from 'manten';

await describe('mac-ocr', async () => {
	// Vision-backed specs are sequential so subprocesses don't contend for the
	// Apple Neural Engine. Pure/shim specs below can run concurrently.
	await import('./specs/ocr.ts');
	await import('./specs/service.ts');
	await import('./specs/pages.ts');
	await import('./specs/searchable-pdf.ts');
	await import('./specs/concurrency.ts');

	import('./specs/languages.ts');
	import('./specs/region-of-interest.ts');
	import('./specs/process.ts');
	import('./specs/wrapper.ts');
});
