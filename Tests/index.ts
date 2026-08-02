import { describe } from 'manten';

await describe('mac-ocr', async () => {
	// Await dedicated-Vision and shared-service suites before starting the next.
	// Pure/shim specs below can run concurrently.
	await import('./specs/ocr.ts');
	await import('./specs/service/index.ts');
	await import('./specs/pages.ts');
	await import('./specs/searchable-pdf.ts');
	await import('./specs/concurrency.ts');

	import('./specs/languages.ts');
	import('./specs/region-of-interest.ts');
	import('./specs/process.ts');
	import('./specs/wrapper.ts');
});
