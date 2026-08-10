import type {
	BoundingBox,
	DocumentContainer,
	DocumentIndexRange,
	DocumentList,
	DocumentListItem,
	DocumentRegion,
	DocumentTable,
	DocumentTableCell,
	DocumentText,
	DocumentTextLine,
	OcrDocumentResult,
	RecognizedDocument,
	TextCandidate,
} from './types.ts';

const isRecord = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === 'object' && !Array.isArray(value);

const getString = (value: unknown): string | undefined => (typeof value === 'string' ? value : undefined);

const getNumber = (value: unknown): number | undefined => (typeof value === 'number' && Number.isFinite(value) ? value : undefined);

const getPositiveInteger = (value: unknown): number | undefined => {
	const number = getNumber(value);
	return number !== undefined && Number.isSafeInteger(number) && number > 0 ? number : undefined;
};

const getBoolean = (value: unknown): boolean | undefined => (
	typeof value === 'boolean' ? value : undefined
);

const getArray = (value: unknown): unknown[] | undefined => (
	Array.isArray(value) ? value : undefined
);

const allDefined = <Value>(values: Array<Value | undefined>): values is Value[] => (
	values.every(value => value !== undefined)
);

const parseBoundingBox = (value: unknown): BoundingBox | undefined => {
	if (!isRecord(value)) {
		return undefined;
	}
	const x = getNumber(value.x);
	const y = getNumber(value.y);
	const width = getNumber(value.width);
	const height = getNumber(value.height);
	if (x === undefined || y === undefined || width === undefined || height === undefined) {
		return undefined;
	}
	return {
		x,
		y,
		width,
		height,
	};
};

const parseRegion = (value: unknown): DocumentRegion | undefined => {
	if (!isRecord(value)) {
		return undefined;
	}
	const points = getArray(value.points)?.map((point) => {
		if (!isRecord(point)) {
			return undefined;
		}
		const x = getNumber(point.x);
		const y = getNumber(point.y);
		return x === undefined || y === undefined
			? undefined
			: {
				x,
				y,
			};
	});
	const boundingBox = parseBoundingBox(value.boundingBox);
	if (points === undefined || !allDefined(points) || boundingBox === undefined) {
		return undefined;
	}
	return {
		points,
		boundingBox,
	};
};

const parseCandidate = (value: unknown): TextCandidate | undefined => {
	if (!isRecord(value)) {
		return undefined;
	}
	const text = getString(value.text);
	const confidence = getNumber(value.confidence);
	return text === undefined || confidence === undefined
		? undefined
		: {
			text,
			confidence,
		};
};

const parseTextLine = (value: unknown): DocumentTextLine | undefined => {
	if (!isRecord(value)) {
		return undefined;
	}
	const transcript = getString(value.transcript);
	const confidence = getNumber(value.confidence);
	const boundingRegion = parseRegion(value.boundingRegion);
	const recognitionLanguages = getArray(value.recognitionLanguages)?.map(getString);
	const isTitle = getBoolean(value.isTitle);
	if (
		transcript === undefined
		|| confidence === undefined
		|| boundingRegion === undefined
		|| recognitionLanguages === undefined
		|| !allDefined(recognitionLanguages)
		|| isTitle === undefined
	) {
		return undefined;
	}
	const candidates = value.candidates === undefined
		? undefined
		: getArray(value.candidates)?.map(parseCandidate);
	if (
		(value.candidates !== undefined && candidates === undefined)
		|| (candidates !== undefined && !allDefined(candidates))
	) {
		return undefined;
	}
	const { textDirection } = value;
	if (
		textDirection !== undefined
		&& textDirection !== 'leftToRight'
		&& textDirection !== 'rightToLeft'
		&& textDirection !== 'topToBottom'
		&& textDirection !== 'unknown'
	) {
		return undefined;
	}
	const { shouldWrapToNextLine } = value;
	if (shouldWrapToNextLine !== undefined && typeof shouldWrapToNextLine !== 'boolean') {
		return undefined;
	}
	return {
		transcript,
		confidence,
		boundingRegion,
		...(candidates === undefined ? undefined : { candidates }),
		recognitionLanguages,
		isTitle,
		...(textDirection === undefined ? undefined : { textDirection }),
		...(shouldWrapToNextLine === undefined ? undefined : { shouldWrapToNextLine }),
	};
};

const parseText = (value: unknown): DocumentText | undefined => {
	if (!isRecord(value)) {
		return undefined;
	}
	const transcript = getString(value.transcript);
	const boundingRegion = parseRegion(value.boundingRegion);
	const lines = getArray(value.lines)?.map(parseTextLine);
	if (
		transcript === undefined
		|| boundingRegion === undefined
		|| lines === undefined
		|| !allDefined(lines)
	) {
		return undefined;
	}
	const { alignment } = value;
	if (alignment !== undefined && alignment !== 'center' && alignment !== 'leading' && alignment !== 'trailing') {
		return undefined;
	}
	return {
		transcript,
		boundingRegion,
		...(alignment === undefined ? undefined : { alignment }),
		lines,
	};
};

const parseIndexRange = (value: unknown): DocumentIndexRange | undefined => {
	if (!isRecord(value)) {
		return undefined;
	}
	const start = getNumber(value.start);
	const end = getNumber(value.end);
	if (
		start === undefined
		|| end === undefined
		|| !Number.isInteger(start)
		|| !Number.isInteger(end)
		|| start < 0
		|| end < 0
		|| start > end
	) {
		return undefined;
	}
	return {
		start,
		end,
	};
};

const parseContainer = (value: unknown, depth = 0): DocumentContainer | undefined => {
	if (!isRecord(value) || depth > 100) {
		return undefined;
	}
	const boundingRegion = parseRegion(value.boundingRegion);
	const text = parseText(value.text);
	const title = value.title === undefined ? undefined : parseText(value.title);
	const paragraphs = getArray(value.paragraphs)?.map(parseText);
	const tables = getArray(value.tables)?.map(table => parseTable(table, depth + 1));
	const lists = getArray(value.lists)?.map(list => parseList(list, depth + 1));
	if (
		boundingRegion === undefined
		|| text === undefined
		|| (value.title !== undefined && title === undefined)
		|| paragraphs === undefined
		|| !allDefined(paragraphs)
		|| tables === undefined
		|| !allDefined(tables)
		|| lists === undefined
		|| !allDefined(lists)
	) {
		return undefined;
	}
	return {
		boundingRegion,
		text,
		...(title === undefined ? undefined : { title }),
		paragraphs,
		tables,
		lists,
	};
};

const parseTable = (value: unknown, depth: number): DocumentTable | undefined => {
	if (!isRecord(value)) {
		return undefined;
	}
	const boundingRegion = parseRegion(value.boundingRegion);
	const rows = getArray(value.rows)?.map((row) => {
		const cells = getArray(row)?.map(cell => parseTableCell(cell, depth + 1));
		return cells !== undefined && allDefined(cells) ? cells : undefined;
	});
	if (boundingRegion === undefined || rows === undefined || !allDefined(rows)) {
		return undefined;
	}
	return {
		boundingRegion,
		rows,
	};
};

const parseTableCell = (value: unknown, depth: number): DocumentTableCell | undefined => {
	if (!isRecord(value)) {
		return undefined;
	}
	const rowRange = parseIndexRange(value.rowRange);
	const columnRange = parseIndexRange(value.columnRange);
	const content = parseContainer(value.content, depth + 1);
	if (rowRange === undefined || columnRange === undefined || content === undefined) {
		return undefined;
	}
	return {
		rowRange,
		columnRange,
		content,
	};
};

const parseList = (value: unknown, depth: number): DocumentList | undefined => {
	if (!isRecord(value)) {
		return undefined;
	}
	const boundingRegion = parseRegion(value.boundingRegion);
	const items = getArray(value.items)?.map(item => parseListItem(item, depth + 1));
	if (boundingRegion === undefined || items === undefined || !allDefined(items)) {
		return undefined;
	}
	return {
		boundingRegion,
		items,
	};
};

const parseListItem = (value: unknown, depth: number): DocumentListItem | undefined => {
	if (!isRecord(value)) {
		return undefined;
	}
	const markerText = getString(value.markerText);
	const text = getString(value.text);
	const content = parseContainer(value.content, depth + 1);
	const { markerType } = value;
	if (
		markerText === undefined
		|| text === undefined
		|| content === undefined
		|| (markerType !== undefined && markerType !== 'bullet' && markerType !== 'hyphen' && markerType !== 'lowercaseLatin' && markerType !== 'uppercaseLatin' && markerType !== 'decimal' && markerType !== 'decorativeDecimal' && markerType !== 'compositeDecimal' && markerType !== 'unknown')
	) {
		return undefined;
	}
	return {
		markerText,
		text,
		content,
		...(markerType === undefined ? undefined : { markerType }),
	};
};

const parseDocument = (value: unknown): RecognizedDocument | undefined => {
	if (!isRecord(value)) {
		return undefined;
	}
	const confidence = getNumber(value.confidence);
	const content = parseContainer(value.content);
	if (confidence === undefined || content === undefined) {
		return undefined;
	}
	return {
		confidence,
		content,
	};
};

export const parseOcrDocumentResult = (value: unknown): OcrDocumentResult | undefined => {
	if (!isRecord(value)) {
		return undefined;
	}
	const schema = getString(value.schema);
	const schemaVersion = getNumber(value.schemaVersion);
	const requestRevision = getPositiveInteger(value.requestRevision);
	const page = getPositiveInteger(value.page);
	const pageCount = getPositiveInteger(value.pageCount);
	const width = getPositiveInteger(value.width);
	const height = getPositiveInteger(value.height);
	const text = getString(value.text);
	const documents = getArray(value.documents)?.map(parseDocument);
	if (
		schema !== 'mac-ocr.document'
		|| schemaVersion !== 1
		|| requestRevision === undefined
		|| page === undefined
		|| pageCount === undefined
		|| width === undefined
		|| height === undefined
		|| text === undefined
		|| documents === undefined
		|| !allDefined(documents)
		|| page > pageCount
	) {
		return undefined;
	}
	return {
		schema,
		schemaVersion,
		requestRevision,
		page,
		pageCount,
		width,
		height,
		text,
		documents,
	};
};
