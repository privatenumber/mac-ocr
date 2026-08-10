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
}, { parallel: false });
