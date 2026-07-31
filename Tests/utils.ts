import fs from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createFixture } from 'fs-fixture';
import type * as WrapperApiModule from '../src/index.ts';
import type * as ServiceModule from '../src/service/index.ts';

export const fixtureData = (name: string): Buffer => fs.readFileSync(
	fileURLToPath(new URL(`fixtures/${name}`, import.meta.url)),
);

const sourceDirectory = fileURLToPath(new URL('../src', import.meta.url));

type WrapperApi = typeof WrapperApiModule;
type ServiceApi = typeof ServiceModule;

/**
 * Import a private copy of the wrapper whose `bin/mac-ocr` is the given shim
 * script — or absent entirely, to exercise spawn failures. The wrapper
 * resolves its binary relative to its own module URL, so copying `src/` into
 * a fixture and importing it from there rebinds the binary path to the
 * fixture's shim; no environment variable is involved. (A symlinked `src`
 * would not work: Node's ESM loader realpaths module URLs, which would escape
 * the fixture.)
 *
 * Each call imports a unique URL and therefore a fresh module graph — use the
 * returned `api` for `instanceof` checks (`api.MacOcrError`), not the classes
 * imported from the real `src/`.
 */
export const importWrapper = async (
	shim?: string,
	options: { service?: boolean } = {},
) => {
	const fixture = await createFixture(
		shim === undefined ? {} : { 'bin/mac-ocr': shim },
	);
	await fixture.cp(sourceDirectory, 'src', { recursive: true });
	if (shim !== undefined) {
		await fs.promises.chmod(fixture.getPath('bin/mac-ocr'), 0o755);
	}
	const [api, serviceApi] = await Promise.all([
		import(pathToFileURL(fixture.getPath('src/index.ts')).href) as Promise<WrapperApi>,
		import(pathToFileURL(fixture.getPath('src/service/index.ts')).href) as Promise<ServiceApi>,
	]);
	if (!options.service) {
		serviceApi.disableServiceForTesting();
	}
	return {
		api,
		serviceApi,

		/** Unique per call — usable as a `pgrep -f` pattern for shim processes. */
		binaryPath: fixture.getPath('bin/mac-ocr'),
		[Symbol.asyncDispose]: async () => {
			await fixture.rm();
		},
	};
};
