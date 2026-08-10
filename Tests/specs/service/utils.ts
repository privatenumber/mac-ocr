import fs from 'node:fs/promises';
import os from 'node:os';
import { setTimeout } from 'node:timers/promises';
import { ocr } from '../../../src/index.ts';
import { servicePidForTesting } from '../../../src/service/index.ts';
import { fixtureData } from '../../utils.ts';

type ServiceShim = {
	setup?: string;
	afterHello?: string;
	onRequest: string;
};

// Keep each test's request behavior inline while sharing valid protocol plumbing.
export const serviceShim = ({
	setup = '',
	afterHello = '',
	onRequest,
}: ServiceShim): string => `#!/usr/bin/env node
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const directory = path.join(os.tmpdir(), 'mac-ocr-service-' + process.pid + '-' + crypto.randomUUID())
fs.mkdirSync(directory, { mode: 0o700 })
const frame = value => {
  const payload = Buffer.from(JSON.stringify(value))
  const header = Buffer.alloc(4)
  header.writeUInt32LE(payload.length)
  process.stdout.write(Buffer.concat([header, payload]))
}
const item = (request, sequence, result) => frame({
  id: request.id,
  type: 'item',
  sequence,
  result,
})
const complete = (request, result) => frame(result === undefined
  ? { id: request.id, type: 'complete' }
  : { id: request.id, type: 'complete', result })
${setup}
frame({ type: 'hello', inputDirectory: directory })
${afterHello}
let buffered = Buffer.alloc(0)
process.stdin.on('data', chunk => {
  buffered = Buffer.concat([buffered, chunk])
  while (buffered.length >= 4) {
    const length = buffered.readUInt32LE(0)
    if (buffered.length < length + 4) return
    const request = JSON.parse(buffered.subarray(4, length + 4))
    buffered = buffered.subarray(length + 4)
    ${onRequest}
  }
})
process.on('exit', () => fs.rmSync(directory, { recursive: true, force: true }))
`;

export const waitFor = async (
	condition: () => boolean | Promise<boolean>,
	message: string,
	timeoutMilliseconds = 2000,
): Promise<void> => {
	const deadline = Date.now() + timeoutMilliseconds;
	while (!await condition() && Date.now() < deadline) {
		await setTimeout(20);
	}
	if (!await condition()) {
		throw new Error(message);
	}
};

export const serviceDirectories = async (): Promise<string[]> => {
	const names = await fs.readdir(os.tmpdir());
	return names.filter(name => /^mac-ocr-service-\d+-[0-9A-Fa-f-]{36}$/.test(name));
};

export const ensureServiceForTesting = async (): Promise<number> => {
	let pid = servicePidForTesting();
	if (pid === undefined) {
		await ocr(fixtureData('hello.png'));
		pid = servicePidForTesting();
	}
	if (pid === undefined) {
		throw new Error('Expected a running service');
	}
	return pid;
};
