import { describe, expect, test } from 'manten';
import { importWrapper } from '../../utils.ts';
import { serviceShim } from './utils.ts';

const documentResult = (page = 1, pageCount = 1) => ({
	schema: 'mac-ocr.document',
	schemaVersion: 1,
	requestRevision: 1,
	page,
	pageCount,
	width: 1,
	height: 1,
	text: `page-${page}`,
	documents: [],
});

const malformedCandidatesResult = {
	...documentResult(),
	documents: [{
		confidence: 1,
		content: {
			boundingRegion: {
				points: [],
				boundingBox: {
					x: 0,
					y: 0,
					width: 1,
					height: 1,
				},
			},
			text: {
				transcript: 'page-1',
				boundingRegion: {
					points: [],
					boundingBox: {
						x: 0,
						y: 0,
						width: 1,
						height: 1,
					},
				},
				lines: [{
					transcript: 'page-1',
					confidence: 1,
					boundingRegion: {
						points: [],
						boundingBox: {
							x: 0,
							y: 0,
							width: 1,
							height: 1,
						},
					},
					candidates: 'invalid',
					recognitionLanguages: [],
					isTitle: false,
				}],
			},
			paragraphs: [],
			tables: [],
			lists: [],
		},
	}],
};

await describe('document service', () => {
	test('returns validated document results and pulls one page at a time', async () => {
		await using wrapper = await importWrapper(serviceShim({
			setup: 'let page = 0',
			onRequest: `if (request.operation === 'document') {
  complete(request, ${JSON.stringify(documentResult())})
} else if (request.operation === 'document-pages') {
} else if (request.command === 'pull') {
  if (page === 2) {
    complete(request)
  } else {
    item(request, page, ${JSON.stringify(documentResult()).replace('"page":1', '"page":page + 1').replace('"pageCount":1', '"pageCount":2').replace('"text":"page-1"', '"text":"page-" + (page + 1)')})
    page += 1
  }
}`,
		}), { service: true });
		const result = await wrapper.api.ocrDocument(Buffer.from('document'));
		const pages = await Array.fromAsync(wrapper.api.ocrDocument.pages(Buffer.from('pages')));
		expect(result).toMatchObject({
			schema: 'mac-ocr.document',
			text: 'page-1',
		});
		expect(pages.map(page => page.page)).toStrictEqual([1, 2]);
	});

	test('rejects malformed document candidates', async () => {
		await using wrapper = await importWrapper(serviceShim({
			onRequest: `if (request.operation === 'document') {
  complete(request, ${JSON.stringify(malformedCandidatesResult)})
}`,
		}), { service: true });
		const error = await wrapper.api.ocrDocument(Buffer.from('document')).catch((error_: unknown) => error_);
		expect(error).toMatchObject({ kind: 'runtime' });
	});

	test('preserves the typed unavailable error', async () => {
		await using wrapper = await importWrapper(serviceShim({
			onRequest: `if (request.operation === 'document') {
  frame({
    id: request.id,
    type: 'error',
    error: {
      kind: 'unavailable',
      code: 'document_recognition_unavailable',
      message: 'Document recognition requires macOS 26 or later',
      exitCode: 1,
      stderr: '',
    },
  })
}`,
		}), { service: true });
		const error = await wrapper.api.ocrDocument(Buffer.from('document')).catch((error_: unknown) => error_);
		expect(error).toMatchObject({
			kind: 'unavailable',
			code: 'document_recognition_unavailable',
		});
	});

	test('rejects a late document page after cancellation', async () => {
		await using wrapper = await importWrapper(serviceShim({
			setup: 'let activeRequest',
			onRequest: `if (request.operation === 'document-pages') {
  activeRequest = request
} else if (request.command === 'cancel' && request.id === activeRequest?.id) {
  item(activeRequest, 0, ${JSON.stringify(documentResult())})
  frame({
    id: activeRequest.id,
    type: 'error',
    error: { kind: 'abort', message: 'aborted', exitCode: null, stderr: '' },
  })
}`,
		}), { service: true });
		const controller = new AbortController();
		const iterator = wrapper.api.ocrDocument.pages(
			Buffer.from('document'),
			{ signal: controller.signal },
		)[Symbol.asyncIterator]();
		const next = iterator.next().catch((error: unknown) => error);
		controller.abort();
		expect(await next).toMatchObject({ kind: 'abort' });
		await iterator.return?.();
	});
}, { parallel: false });
