import fs from 'node:fs/promises';
import path from 'node:path';
import { describe, expect, test } from 'manten';
import { importWrapper } from '../../utils.ts';
import { serviceShim } from './utils.ts';

type LoggedRequest = {
	pid: number;
	operation?: string;
	command?: string;
	outputName?: string;
};

const result = (page: number, text: string) => ({
	page,
	pageCount: 2,
	width: 1,
	height: 1,
	text,
	observations: [],
});

await describe('shared APIs', () => {
	test('uses one service FIFO for mixed APIs and removes PDF artifacts', async () => {
		await using wrapper = await importWrapper(serviceShim({
			setup: `const requestLogPath = path.join(__dirname, 'requests.json')
const inputDirectoryPath = path.join(__dirname, 'input-directory')
fs.writeFileSync(requestLogPath, '')
fs.writeFileSync(inputDirectoryPath, directory)
let page = 0`,
			onRequest: String.raw`fs.appendFileSync(requestLogPath, JSON.stringify({ ...request, pid: process.pid }) + '\n')
if (request.operation === 'ocr') {
  complete(request, { page: 1, pageCount: 1, width: 1, height: 1, text: 'ocr', observations: [] })
} else if (request.operation === 'ocr-pages') {
} else if (request.command === 'pull') {
  if (page === 2) {
    complete(request)
  } else {
    item(request, page, { page: page + 1, pageCount: 2, width: 1, height: 1, text: 'page-' + (page + 1), observations: [] })
    page += 1
  }
} else if (request.operation === 'searchable-pdf') {
  if (typeof request.outputName !== 'string') throw new Error('Expected PDF output name')
  const artifact = Buffer.from('%PDF-shim')
  fs.writeFileSync(path.join(directory, request.outputName), artifact)
  complete(request, { name: request.outputName, size: artifact.byteLength })
} else if (request.operation === 'languages') {
  complete(request, ['en-US', 'ja'])
} else {
  frame({
    id: request.id,
    type: 'error',
    error: { kind: 'usage', message: 'Unexpected request', exitCode: null, stderr: '' },
  })
}`,
		}), { service: true });
		const logDirectory = path.dirname(wrapper.binaryPath);
		const [ocrResult, pages, pdf, languages] = await Promise.all([
			wrapper.api.ocr(Buffer.from('ocr')),
			Array.fromAsync(wrapper.api.ocr.pages(Buffer.from('pages'))),
			wrapper.api.createSearchablePdf(Buffer.from('pdf')),
			wrapper.api.supportedLanguages(),
		]);
		const requestLog = await fs.readFile(path.join(logDirectory, 'requests.json'), 'utf8');
		const requests = requestLog
			.trim()
			.split('\n')
			.map(line => JSON.parse(line) as LoggedRequest);
		const inputDirectory = await fs.readFile(path.join(logDirectory, 'input-directory'), 'utf8');
		const pdfRequest = requests.find(request => request.operation === 'searchable-pdf');

		expect(ocrResult.text).toBe('ocr');
		expect(pages).toStrictEqual([result(1, 'page-1'), result(2, 'page-2')]);
		expect(Buffer.from(pdf).toString('utf8')).toBe('%PDF-shim');
		expect(languages).toStrictEqual(['en-US', 'ja']);
		expect(requests.map(request => request.operation ?? request.command)).toStrictEqual([
			'ocr',
			'ocr-pages',
			'pull',
			'pull',
			'pull',
			'searchable-pdf',
			'languages',
		]);
		expect(requests.filter(request => request.command !== 'pull').every(
			request => request.command === undefined,
		)).toBe(true);
		expect(new Set(requests.map(request => request.pid))).toStrictEqual(new Set([
			wrapper.serviceApi.servicePidForTesting(),
		]));
		const outputName = pdfRequest?.outputName;
		if (!outputName) {
			throw new Error('Expected PDF output name');
		}
		const artifactPath = path.join(inputDirectory, outputName);
		await expect(fs.access(artifactPath)).rejects.toMatchObject({
			code: 'ENOENT',
		});
	});
}, { parallel: false });
