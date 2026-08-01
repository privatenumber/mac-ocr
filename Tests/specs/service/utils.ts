import fs from 'node:fs/promises';
import os from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';
import { ocr } from '../../../src/index.ts';
import { servicePidForTesting } from '../../../src/service/index.ts';
import { fixtureData } from '../../utils.ts';

export const processExists = (pid: number): boolean => {
	try {
		process.kill(pid, 0);
		return true;
	} catch {
		return false;
	}
};

export const waitFor = async (
	condition: () => boolean | Promise<boolean>,
	message: string,
	timeoutMilliseconds = 2000,
): Promise<void> => {
	const deadline = Date.now() + timeoutMilliseconds;
	while (!await condition() && Date.now() < deadline) {
		await delay(20);
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
