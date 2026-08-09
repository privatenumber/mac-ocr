import { createInterface } from 'node:readline';
import { MacOcrError } from './errors.ts';
import { waitForExit, type Spawned } from './process.ts';
import type { Input } from './types.ts';

type PageResult = {
	page: number;
	pageCount: number;
};

type PageAnalysisOptions = {
	signal?: AbortSignal;
};

type CreatePageAnalysisOptions<Result extends PageResult, Options extends PageAnalysisOptions> = {
	label: string;
	multiPageMessage: string;
	pageReuseMessage: string;
	missingPageMessage: (yielded: number, expected: number) => string;
	spawn: (input: Input, options?: Options) => Spawned;
	parseLine: (line: string) => Result | undefined;
};

export type PageAnalysis<Result, Options> = {
	singleProcess: (input: Input, options?: Options) => Promise<Result>;
	pages: (input: Input, options?: Options) => AsyncIterable<Result>;
};

export const createPageAnalysis = <Result extends PageResult, Options extends PageAnalysisOptions>(
	options: CreatePageAnalysisOptions<Result, Options>,
): PageAnalysis<Result, Options> => {
	const validatePage = (page: Result, expectedPageCount?: number): void => {
		if (
			!Number.isSafeInteger(page.page)
			|| !Number.isSafeInteger(page.pageCount)
			|| page.page < 1
			|| page.pageCount < 1
			|| page.page > page.pageCount
			|| (expectedPageCount !== undefined && page.pageCount !== expectedPageCount)
		) {
			throw new MacOcrError(`${options.label} produced invalid page metadata`, { kind: 'parse' });
		}
	};

	const singleProcess = async (input: Input, analysisOptions?: Options): Promise<Result> => {
		const spawned = options.spawn(input, analysisOptions);
		let first: Result | undefined;

		try {
			for await (const line of createInterface({ input: spawned.proc.stdout })) {
				const page = options.parseLine(line);
				if (page !== undefined) {
					first = page;
					break;
				}
			}
		} catch (error) {
			await waitForExit(spawned, options.label);
			throw new MacOcrError(`${options.label} output could not be read`, {
				kind: 'parse',
				cause: error,
			});
		}

		if (first !== undefined && first.pageCount > 1) {
			validatePage(first);
			spawned.proc.kill();
			await spawned.exit.catch(() => {});
			throw new MacOcrError(options.multiPageMessage, { kind: 'usage' });
		}

		await waitForExit(spawned, options.label);
		if (first === undefined) {
			throw new MacOcrError(`${options.label} produced no output`, { kind: 'parse' });
		}
		validatePage(first);
		return first;
	};

	const pages = (input: Input, analysisOptions?: Options): AsyncIterable<Result> => {
		let consumed = false;

		const iterate = async function* iterate(): AsyncGenerator<Result> {
			if (consumed) {
				throw new MacOcrError(options.pageReuseMessage, { kind: 'usage' });
			}
			consumed = true;

			const spawned = options.spawn(input, analysisOptions);
			let completed = false;
			let yielded = 0;
			let expectedPageCount: number | undefined;
			try {
				for await (const line of createInterface({ input: spawned.proc.stdout })) {
					const page = options.parseLine(line);
					if (page !== undefined) {
						validatePage(page, expectedPageCount);
						if (page.page !== yielded + 1) {
							throw new MacOcrError(`${options.label} produced pages out of order`, { kind: 'parse' });
						}
						expectedPageCount = page.pageCount;
						yielded += 1;
						yield page;
					}
				}
				completed = true;
			} finally {
				if (completed) {
					await waitForExit(spawned, options.label);
				} else {
					spawned.proc.kill();
					await spawned.exit.catch(() => {});
				}
			}

			if (expectedPageCount === undefined) {
				throw new MacOcrError(`${options.label} produced no output`, { kind: 'parse' });
			}
			if (yielded !== expectedPageCount) {
				throw new MacOcrError(options.missingPageMessage(yielded, expectedPageCount), { kind: 'parse' });
			}
		};

		return { [Symbol.asyncIterator]: iterate };
	};

	return { singleProcess, pages };
};
