import { describe, test, expect } from 'manten';
import type { MacOcrError } from '../../src/index.ts';
import { importWrapper } from '../utils.ts';

describe('process', () => {
	// A failed spawn (ENOENT) used to crash the host on an uncaught 'error'.
	// Verify it rejects with a typed spawn error instead. The fixture has no
	// bin/mac-ocr at all, so the spawn fails exactly like a broken install.
	test('rejects cleanly when the binary cannot spawn', async () => {
		await using wrapper = await importWrapper();
		const error = await wrapper.api.ocr(Buffer.from('dummy')).catch((error_: unknown) => error_);
		expect(error).toBeInstanceOf(wrapper.api.MacOcrError);
		expect((error as MacOcrError).kind).toBe('spawn');
	});
});
