import { spawn } from 'node:child_process';
import { once } from 'node:events';
import path from 'node:path';
import { describe, expect, test } from 'manten';
import { isNativeHello } from '../../../src/service/protocol.ts';
import { importWrapper } from '../../utils.ts';
import { serviceShim } from './utils.ts';

await describe('protocol', () => {
	test('accepts service directories under a relative TMPDIR', () => {
		const previous = process.env.TMPDIR;
		process.env.TMPDIR = '.';
		try {
			expect(isNativeHello({
				type: 'hello',
				inputDirectory: path.join(
					process.cwd(),
					'mac-ocr-service-123-00000000-0000-0000-0000-000000000000',
				),
			})).toBe(true);
		} finally {
			if (previous === undefined) {
				delete process.env.TMPDIR;
			} else {
				process.env.TMPDIR = previous;
			}
		}
	});

	test('rejects malformed protocol frames instead of crashing', async () => {
		await using wrapper = await importWrapper(`#!/usr/bin/env node
const payload = Buffer.from('null')
const header = Buffer.alloc(4)
header.writeUInt32LE(payload.length)
process.stdout.write(Buffer.concat([header, payload]))
setTimeout(() => {}, 30_000)
`, { service: true });
		const error = await wrapper.api.ocr(Buffer.from('x')).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(wrapper.api.MacOcrError);
		expect(error).toMatchObject({ kind: 'runtime' });
		expect((error as Error).message).toMatch(/invalid hello frame/);
	});

	test('keeps stderr scoped to its structured response', async () => {
		await using wrapper = await importWrapper(serviceShim({
			onRequest: String.raw`process.stderr.write('diagnostic from another request\n')
frame({
  id: request.id,
  type: 'error',
  error: { kind: 'usage', message: 'request failed', exitCode: null, stderr: '' },
})`,
		}), { service: true });
		const error = await wrapper.api.ocr(Buffer.from('x')).catch((error_: unknown) => error_);
		expect(error).toMatchObject({ stderr: '' });
	});

	test('rejects every response after an unknown request ID', async () => {
		await using wrapper = await importWrapper(serviceShim({
			onRequest: `const result = { page: 1, pageCount: 1, width: 1, height: 1, text: 'invalid success', observations: [] }
const payload = value => {
  const json = Buffer.from(JSON.stringify(value))
  const header = Buffer.alloc(4)
  header.writeUInt32LE(json.length)
  return Buffer.concat([header, json])
}
process.stdout.write(Buffer.concat([
  payload({ id: request.id + 1, type: 'result', result }),
  payload({ id: request.id, type: 'result', result }),
]))`,
		}), { service: true });
		const outcome = await wrapper.api.ocr(Buffer.from('x')).catch((error: unknown) => error);
		expect(outcome).toMatchObject({ kind: 'runtime' });
		expect((outcome as Error).message).toMatch(/unknown request ID/);
	});

	test('bounds stderr retained across service requests', async () => {
		await using wrapper = await importWrapper(serviceShim({
			setup: `const diagnostic = Buffer.alloc(1024 * 1024, 120)
let requestCount = 0`,
			onRequest: `requestCount += 1
process.stderr.write(diagnostic, () => {
  if (requestCount === 5) {
    process.exit(1)
  }
  frame({
    id: request.id,
    type: 'result',
    result: { page: 1, pageCount: 1, width: 1, height: 1, text: 'ok', observations: [] },
  })
})`,
		}), { service: true });
		for (let index = 0; index < 4; index += 1) {
			await wrapper.api.ocr(Buffer.from('x'));
		}
		const error = await wrapper.api.ocr(Buffer.from('x')).catch((error_: unknown) => error_);
		expect(error).toMatchObject({ kind: 'runtime' });
		expect(Buffer.byteLength((error as { stderr: string }).stderr)).toBeLessThanOrEqual(64 * 1024);
	});

	test('releases oversized frame buffers after draining', async () => {
		const protocolUrl = new URL('../../../src/service/protocol.ts', import.meta.url).href;
		const source = `
import { createFrameDecoder } from ${JSON.stringify(protocolUrl)}
globalThis.gc()
const baseline = process.memoryUsage().arrayBuffers
let payload = Buffer.alloc(40 * 1024 * 1024)
const header = Buffer.alloc(4)
header.writeUInt32LE(payload.length)
let frame = Buffer.concat([header, payload])
const decode = createFrameDecoder(() => true, message => { throw new Error(message) })
decode(frame)
payload = undefined
frame = undefined
globalThis.gc()
process.stdout.write(String(process.memoryUsage().arrayBuffers - baseline))
`;
		const child = spawn(process.execPath, [
			'--expose-gc',
			'--input-type=module',
			'--eval',
			source,
		]);
		let stdout = '';
		let stderr = '';
		child.stdout.on('data', (chunk) => {
			stdout += chunk;
		});
		child.stderr.on('data', (chunk) => {
			stderr += chunk;
		});
		const [code] = await once(child, 'close');
		expect(code).toBe(0);
		expect(stderr).toBe('');
		expect(Number(stdout)).toBeLessThan(5 * 1024 * 1024);
	});
}, { parallel: 2 });
