import { createInterface } from 'node:readline';
import childProcess from 'node:child_process';
import { fileURLToPath } from 'node:url';

const toTuple = (roi) => {
  if (Array.isArray(roi)) {
    if (roi.length !== 4) {
      throw new TypeError(`regionOfInterest tuple must have four values [x, y, width, height]; got ${roi.length}`);
    }
    return [roi[0], roi[1], roi[2], roi[3]];
  }
  const box = roi;
  return [box.x, box.y, box.width, box.height];
};
const requireUnit = (name, value) => {
  if (!Number.isFinite(value) || value < 0 || value > 1) {
    throw new RangeError(`regionOfInterest.${name} must be a finite number in [0, 1]; got ${value}`);
  }
};
const serializeRegionOfInterest = (roi) => {
  if (typeof roi === "string") {
    return roi;
  }
  if (roi === null || typeof roi !== "object") {
    throw new TypeError(`regionOfInterest must be an object, tuple, or string; got ${typeof roi}`);
  }
  const [x, y, width, height] = toTuple(roi);
  requireUnit("x", x);
  requireUnit("y", y);
  requireUnit("width", width);
  requireUnit("height", height);
  if (width <= 0 || height <= 0) {
    throw new RangeError(`regionOfInterest width and height must be positive; got ${width}, ${height}`);
  }
  if (x + width > 1 || y + height > 1) {
    throw new RangeError(`regionOfInterest extends past the image (x+width=${x + width}, y+height=${y + height}); both must be <= 1`);
  }
  return `${x},${y},${width},${height}`;
};
const buildArgs = (options) => {
  const args = [];
  if (options?.fast) {
    args.push("--fast");
  }
  if (options?.languages) {
    for (const language of options.languages) {
      args.push("--language", language);
    }
  }
  if (options?.confidence !== void 0) {
    args.push("--confidence", String(options.confidence));
  }
  if (options?.customWords) {
    for (const word of options.customWords) {
      args.push("--custom-words", word);
    }
  }
  if (options?.languageCorrection === false) {
    args.push("--no-language-correction");
  }
  if (options?.minTextHeight !== void 0) {
    args.push("--min-text-height", String(options.minTextHeight));
  }
  if (options?.maxCandidates !== void 0) {
    args.push("--max-candidates", String(options.maxCandidates));
  }
  if (options?.regionOfInterest !== void 0) {
    args.push("--roi", serializeRegionOfInterest(options.regionOfInterest));
  }
  if (options?.pdfDpi !== void 0) {
    args.push("--pdf-dpi", String(options.pdfDpi));
  }
  return args;
};

class MacOcrError extends Error {
  kind;
  code;
  exitCode;
  stderr;
  constructor(message, options) {
    super(message, { cause: options.cause });
    this.name = "MacOcrError";
    this.kind = options.kind;
    this.code = options.code;
    this.exitCode = options.exitCode ?? null;
    this.stderr = options.stderr ?? "";
  }
}

const binaryPath = fileURLToPath(new URL("../bin/mac-ocr", import.meta.url));
const toBuffer = (input) => {
  if (Buffer.isBuffer(input)) {
    return input;
  }
  if (input instanceof ArrayBuffer) {
    return Buffer.from(input);
  }
  if (input instanceof Uint8Array) {
    return Buffer.from(input.buffer, input.byteOffset, input.byteLength);
  }
  throw new TypeError("Input must be a Buffer, Uint8Array, or ArrayBuffer of image/PDF bytes.");
};
const spawnBinary = (args, options = {}) => {
  const stdin = options.input === void 0 ? void 0 : toBuffer(options.input);
  const proc = childProcess.spawn(binaryPath, args, {
    env: {
      ...process.env,
      MAC_OCR_ERROR_FORMAT: "json",
      // The CLI treats an empty password as unset, so only forward
      // non-empty values; an ambient MAC_OCR_PDF_PASSWORD still flows
      // through process.env above (the documented fallback).
      ...options.password ? { MAC_OCR_PDF_PASSWORD: options.password } : void 0
    },
    signal: options.signal,
    stdio: ["pipe", "pipe", "pipe", "pipe"]
  });
  const stderrChunks = [];
  const machineErrorChunks = [];
  proc.stderr.on("data", (chunk) => stderrChunks.push(chunk));
  proc.stdio[3]?.on("data", (chunk) => machineErrorChunks.push(chunk));
  const exit = new Promise((resolve, reject) => {
    proc.once("error", reject);
    proc.once("close", (code, signalName) => resolve({
      code,
      signal: signalName
    }));
  });
  exit.catch(() => {
  });
  proc.stdin.on("error", () => {
  });
  if (stdin === void 0) {
    proc.stdin.end();
  } else {
    proc.stdin.end(stdin);
  }
  return {
    proc,
    exit,
    signal: options.signal,
    stderrChunks,
    machineErrorChunks
  };
};
const stderrText = (spawned) => Buffer.concat(spawned.stderrChunks).toString("utf8").trim();
const isAbortError = (error) => error instanceof Error && (error.name === "AbortError" || /abort/i.test(error.message));
const parseErrorEnvelope = (spawned) => {
  const text = Buffer.concat(spawned.machineErrorChunks).toString("utf8").trim();
  if (!text) {
    return void 0;
  }
  const lastLine = text.split("\n").findLast(Boolean);
  if (!lastLine) {
    return void 0;
  }
  try {
    const envelope = JSON.parse(lastLine);
    if (envelope?.schema === "mac-ocr.error" && envelope.schemaVersion === 1) {
      return envelope;
    }
  } catch {
  }
  return void 0;
};
const waitForExit = async (spawned, label) => {
  let result;
  try {
    result = await spawned.exit;
  } catch (error) {
    if (spawned.signal?.aborted || isAbortError(error)) {
      throw new MacOcrError(`${label} was aborted`, {
        kind: "abort",
        stderr: stderrText(spawned),
        cause: error
      });
    }
    const detail = error instanceof Error ? error.message : String(error);
    throw new MacOcrError(`${label} failed to start: ${detail}`, {
      kind: "spawn",
      stderr: stderrText(spawned),
      cause: error
    });
  }
  if (result.signal !== null) {
    const stderr = stderrText(spawned);
    if (spawned.signal?.aborted) {
      throw new MacOcrError(stderr || `${label} was aborted`, {
        kind: "abort",
        stderr
      });
    }
    throw new MacOcrError(stderr || `${label} was killed by ${result.signal}`, {
      kind: "runtime",
      stderr
    });
  }
  if (result.code !== 0) {
    const stderr = stderrText(spawned);
    const envelope = parseErrorEnvelope(spawned);
    const kind = envelope?.kind ?? (result.code === 64 ? "usage" : "runtime");
    const message = stderr.replace(/^Error:\s*/, "") || envelope?.message || `${label} exited with code ${result.code}`;
    throw new MacOcrError(message, {
      kind,
      code: envelope?.code,
      exitCode: result.code,
      stderr
    });
  }
};
const collectStdout = async (spawned, label) => {
  const chunks = [];
  spawned.proc.stdout.on("data", (chunk) => chunks.push(chunk));
  await waitForExit(spawned, label);
  return Buffer.concat(chunks);
};

const label = "mac-ocr ocr";
const parseLine = (line) => {
  if (!line.startsWith("{")) {
    return void 0;
  }
  let parsed;
  try {
    parsed = JSON.parse(line);
  } catch {
    return void 0;
  }
  const { source, ...result } = parsed;
  return result;
};
const spawnOcr = (input, options) => spawnBinary(
  ["ocr", "--format", "jsonl", ...buildArgs(options), "-"],
  {
    input,
    signal: options?.signal,
    password: options?.password
  }
);
const ocrSingle = async (input, options) => {
  const spawned = spawnOcr(input, options);
  let first;
  try {
    for await (const line of createInterface({ input: spawned.proc.stdout })) {
      const page = parseLine(line);
      if (page !== void 0) {
        first = page;
        break;
      }
    }
  } catch (error) {
    await waitForExit(spawned, label);
    throw new MacOcrError(`${label} output could not be read`, {
      kind: "parse",
      cause: error
    });
  }
  if (first !== void 0 && first.pageCount > 1) {
    spawned.proc.kill();
    await spawned.exit.catch(() => {
    });
    throw new MacOcrError(
      "Input has multiple pages. Use `ocr.pages()` to read them all.",
      { kind: "usage" }
    );
  }
  await waitForExit(spawned, label);
  if (first === void 0) {
    throw new MacOcrError(`${label} produced no output`, { kind: "parse" });
  }
  return first;
};
const ocrPages = (input, options) => {
  let consumed = false;
  const iterate = async function* iterate2() {
    if (consumed) {
      throw new MacOcrError(
        "This ocr.pages() result was already consumed. Call ocr.pages() again to re-read it.",
        { kind: "usage" }
      );
    }
    consumed = true;
    const spawned = spawnOcr(input, options);
    let completed = false;
    let yielded = 0;
    let expectedPageCount;
    try {
      for await (const line of createInterface({ input: spawned.proc.stdout })) {
        const page = parseLine(line);
        if (page !== void 0) {
          yielded += 1;
          expectedPageCount = page.pageCount;
          yield page;
        }
      }
      completed = true;
    } finally {
      if (completed) {
        await waitForExit(spawned, label);
      } else {
        spawned.proc.kill();
        await spawned.exit.catch(() => {
        });
      }
    }
    if (expectedPageCount === void 0) {
      throw new MacOcrError(`${label} produced no output`, { kind: "parse" });
    }
    if (yielded < expectedPageCount) {
      throw new MacOcrError(
        `${label} produced ${yielded} of ${expectedPageCount} pages \u2014 some output could not be parsed`,
        { kind: "parse" }
      );
    }
  };
  return { [Symbol.asyncIterator]: iterate };
};
const ocr = Object.assign(ocrSingle, {
  pages: ocrPages
});

const buildSearchablePdfArgs = (options) => {
  const args = ["searchable-pdf", ...buildArgs(options)];
  if (options?.ocrAllPages) {
    args.push("--ocr-all-pages");
  }
  if (options?.imageQuality !== void 0) {
    args.push("--image-quality", String(options.imageQuality));
  }
  if (options?.imagePageDpi !== void 0) {
    args.push("--image-page-dpi", String(options.imagePageDpi));
  }
  if (options?.imageDownsampleDpi !== void 0) {
    args.push("--image-downsample-dpi", String(options.imageDownsampleDpi));
  }
  args.push("-o", "-", "-");
  return args;
};
const createSearchablePdf = async (input, options) => {
  const stdout = await collectStdout(
    spawnBinary(buildSearchablePdfArgs(options), {
      input,
      signal: options?.signal,
      password: options?.password
    }),
    "mac-ocr searchable-pdf"
  );
  return stdout;
};

const supportedLanguages = async (options) => {
  const args = ["languages"];
  if (options?.fast) {
    args.push("--fast");
  }
  const stdout = await collectStdout(spawnBinary(args), "mac-ocr languages");
  return stdout.toString("utf8").trim().split("\n").filter(Boolean);
};

export { MacOcrError, createSearchablePdf, ocr, supportedLanguages };
