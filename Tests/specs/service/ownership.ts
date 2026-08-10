import { spawn } from 'node:child_process';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { Worker } from 'node:worker_threads';
import { describe, expect, test } from 'manten';
import {
	servicePidForTesting,
	stopService,
} from '../../../src/service/index.ts';
import { processExists } from '../../utils.ts';
import { serviceDirectories, waitFor } from './utils.ts';

await describe('ownership', () => {
	test('stops and removes staged inputs when its Node parent exits', async () => {
		stopService();
		await waitFor(
			() => servicePidForTesting() === undefined,
			'Expected no cleanup service before the ownership test',
		);
		const indexUrl = pathToFileURL(new URL('../../../src/index.ts', import.meta.url).pathname).href;
		const serviceUrl = pathToFileURL(
			new URL('../../../src/service/index.ts', import.meta.url).pathname,
		).href;
		const fixtureUrl = pathToFileURL(
			new URL('../../fixtures/document-photo.png', import.meta.url).pathname,
		).href;
		const script = `
import fs from 'node:fs/promises'
import { ocr } from ${JSON.stringify(indexUrl)}
import { servicePidForTesting } from ${JSON.stringify(serviceUrl)}
void ocr(await fs.readFile(new URL(${JSON.stringify(fixtureUrl)})))
while (servicePidForTesting() === undefined) await new Promise(resolve => setTimeout(resolve, 10))
process.stdout.write(String(servicePidForTesting()))
process.stdin.resume()
await new Promise(resolve => process.stdin.once('end', resolve))
process.exit(0)
`;
		const parent = spawn(process.execPath, ['--input-type=module', '--eval', script]);
		let stderr = '';
		parent.stderr.on('data', (chunk) => {
			stderr += chunk;
		});
		try {
			const close = once(parent, 'close');
			const servicePid = await Promise.race([
				once(parent.stdout, 'data').then(([chunk]) => Number(chunk)),
				close.then(([code]) => {
					throw new Error(`Helper exited ${code}: ${stderr}`);
				}),
			]);
			expect(servicePid).toBeGreaterThan(0);
			let serviceDirectory: string | undefined;
			await waitFor(
				async () => {
					const directories = await serviceDirectories();
					serviceDirectory = directories.find(
						name => name.startsWith(`mac-ocr-service-${servicePid}-`),
					);
					if (!serviceDirectory) {
						return false;
					}
					const stagedInputs = await fs.readdir(path.join(os.tmpdir(), serviceDirectory));
					return stagedInputs.length > 0;
				},
				'Expected active work to have a staged input',
			);
			parent.stdin.end();
			const [code] = await close;
			expect(code).toBe(0);
			await waitFor(
				() => !processExists(servicePid),
				'Expected the orphaned service process to stop',
				7000,
			);
			await waitFor(
				async () => {
					const directories = await serviceDirectories();
					return !serviceDirectory || !directories.includes(serviceDirectory);
				},
				'Expected the orphaned service directory to be removed',
				7000,
			);
		} finally {
			if (parent.exitCode === null) {
				parent.kill();
			}
		}
	});

	test('does not keep Node alive after becoming idle', async (context) => {
		const signal = context?.signal ?? AbortSignal.abort();
		const indexUrl = pathToFileURL(new URL('../../../src/index.ts', import.meta.url).pathname).href;
		const fixtureUrl = pathToFileURL(
			new URL('../../fixtures/hello.png', import.meta.url).pathname,
		).href;
		const source = `
import fs from 'node:fs/promises'
import { ocr } from ${JSON.stringify(indexUrl)}
await ocr(await fs.readFile(new URL(${JSON.stringify(fixtureUrl)})))
`;
		const child = spawn(process.execPath, [
			'--input-type=module',
			'--eval',
			source,
		], { stdio: ['ignore', 'ignore', 'pipe'] });
		try {
			const [code, signalName] = await once(child, 'close', { signal });
			expect([code, signalName]).toStrictEqual([0, null]);
		} finally {
			if (child.exitCode === null) {
				child.kill();
			}
		}
	}, 5000);

	test('keeps worker-thread calls on the one-shot path', async () => {
		const indexUrl = pathToFileURL(new URL('../../../src/index.ts', import.meta.url).pathname).href;
		const serviceUrl = pathToFileURL(
			new URL('../../../src/service/index.ts', import.meta.url).pathname,
		).href;
		const fixtureUrl = pathToFileURL(
			new URL('../../fixtures/hello.png', import.meta.url).pathname,
		).href;
		const source = `
import fs from 'node:fs/promises'
import { parentPort } from 'node:worker_threads'
import { ocr, ocrDocument } from ${JSON.stringify(indexUrl)}
import { servicePidForTesting } from ${JSON.stringify(serviceUrl)}
const bytes = await fs.readFile(new URL(${JSON.stringify(fixtureUrl)}))
const result = await ocr(bytes)
const document = await ocrDocument(bytes).catch(error => ({ kind: error.kind }))
parentPort.postMessage([result.text.includes('Hello World'), document.schema ?? document.kind, servicePidForTesting() ?? null])
`;
		const worker = new Worker(new URL(`data:text/javascript,${encodeURIComponent(source)}`));
		const message = once(worker, 'message');
		const exit = once(worker, 'exit');
		try {
			const [workerMessage] = await message as [[boolean, string, number | null]];
			const [recognized, documentResult, servicePid] = workerMessage;
			expect(recognized).toBe(true);
			expect(['mac-ocr.document', 'unavailable']).toContain(documentResult);
			expect(servicePid).toBeNull();
			expect(await exit).toStrictEqual([0]);
		} finally {
			await worker.terminate();
		}
	});
}, { parallel: false });
