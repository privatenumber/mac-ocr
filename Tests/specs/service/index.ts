import { describe } from 'manten';

await describe('ocr service', async () => {
	await import('./requests.ts');
	await import('./admission.ts');
	await import('./cancellation.ts');
	await import('./protocol.ts');
	await import('./recovery.ts');
	await import('./ownership.ts');
	await import('./shared-apis.ts');
	await import('./document.ts');
});
