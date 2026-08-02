import os from 'node:os';
import path from 'node:path';
import { MacOcrError, type MacOcrErrorKind } from '../errors.ts';
import type { OcrResult } from '../types.ts';

const maxFrameBytes = 64 * 1024 * 1024;
const initialFrameBufferBytes = 16 * 1024;
const serviceDirectoryPattern = /^mac-ocr-service-\d+-[0-9A-Fa-f-]{36}$/;

export type NativeHello = {
	type: 'hello';
	inputDirectory: string;
};

type NativeError = {
	kind: MacOcrErrorKind;
	code?: string;
	message: string;
	exitCode?: number | null;
	stderr: string;
};

export type NativeResponse = {
	id: number;
	type: 'result';
	result: OcrResult;
} | {
	id: number;
	type: 'error';
	error: NativeError;
};

const normalizeProtocolString = (_key: string, value: unknown): unknown => (
	typeof value === 'string' ? value.toWellFormed() : value
);

export const encodeFrame = (value: unknown): Buffer => {
	const payload = Buffer.from(JSON.stringify(value, normalizeProtocolString), 'utf8');
	if (payload.byteLength > maxFrameBytes) {
		throw new MacOcrError('mac-ocr service request exceeds the 64 MiB limit', { kind: 'usage' });
	}
	const header = Buffer.allocUnsafe(4);
	header.writeUInt32LE(payload.byteLength);
	return Buffer.concat([header, payload]);
};

const isServiceInputDirectory = (directory: string): boolean => {
	const normalizedDirectory = path.resolve(directory);
	return (
		path.dirname(normalizedDirectory) === path.resolve(os.tmpdir())
		&& serviceDirectoryPattern.test(path.basename(normalizedDirectory))
	);
};

const isRecord = (value: unknown): value is Record<string, unknown> => (
	typeof value === 'object'
	&& value !== null
	&& !Array.isArray(value)
);

export const isNativeHello = (value: unknown): value is NativeHello => (
	isRecord(value)
	&& value.type === 'hello'
	&& typeof value.inputDirectory === 'string'
	&& isServiceInputDirectory(value.inputDirectory)
);

const isNativeError = (value: unknown): value is NativeError => (
	isRecord(value)
	&& (
		value.kind === 'usage'
		|| value.kind === 'unavailable'
		|| value.kind === 'runtime'
		|| value.kind === 'internal'
		|| value.kind === 'abort'
	)
	&& (value.code === undefined || typeof value.code === 'string')
	&& typeof value.message === 'string'
	&& (
		value.exitCode === undefined
		|| value.exitCode === null
		|| (typeof value.exitCode === 'number' && Number.isInteger(value.exitCode))
	)
	&& typeof value.stderr === 'string'
);

const isOcrResult = (value: unknown): value is OcrResult => (
	isRecord(value)
	&& typeof value.page === 'number'
	&& Number.isInteger(value.page)
	&& typeof value.pageCount === 'number'
	&& Number.isInteger(value.pageCount)
	&& typeof value.width === 'number'
	&& Number.isInteger(value.width)
	&& typeof value.height === 'number'
	&& Number.isInteger(value.height)
	&& typeof value.text === 'string'
	&& Array.isArray(value.observations)
);

export const isNativeResponse = (value: unknown): value is NativeResponse => {
	if (
		!isRecord(value)
		|| typeof value.id !== 'number'
		|| !Number.isInteger(value.id)
		|| value.id < 0
		|| value.id > 4_294_967_295
	) {
		return false;
	}
	return (
		(value.type === 'result' && isOcrResult(value.result))
		|| (value.type === 'error' && isNativeError(value.error))
	);
};

export const createFrameDecoder = (
	onFrame: (frame: Buffer) => boolean,
	onFailure: (message: string) => void,
): ((chunk: Buffer) => void) => {
	let stdout = Buffer.allocUnsafe(initialFrameBufferBytes);
	let stdoutUsed = 0;
	return (chunk) => {
		const required = stdoutUsed + chunk.byteLength;
		if (required > stdout.byteLength) {
			const expanded = Buffer.allocUnsafe(Math.max(required, stdout.byteLength * 2));
			stdout.copy(expanded, 0, 0, stdoutUsed);
			stdout = expanded;
		}
		chunk.copy(stdout, stdoutUsed);
		stdoutUsed = required;
		let offset = 0;
		while (offset + 4 <= stdoutUsed) {
			const length = stdout.readUInt32LE(offset);
			if (length > maxFrameBytes) {
				onFailure('mac-ocr service response exceeds the 64 MiB limit');
				return;
			}
			if (offset + 4 + length > stdoutUsed) {
				break;
			}
			offset += 4;
			if (!onFrame(stdout.subarray(offset, offset + length))) {
				return;
			}
			offset += length;
		}
		if (offset > 0) {
			stdout.copyWithin(0, offset, stdoutUsed);
			stdoutUsed -= offset;
		}
		const retainedCapacity = Math.max(initialFrameBufferBytes, stdoutUsed * 2);
		if (stdout.byteLength > retainedCapacity) {
			const compact = Buffer.allocUnsafe(retainedCapacity);
			stdout.copy(compact, 0, 0, stdoutUsed);
			stdout = compact;
		}
	};
};
