# Benchmark

On-device throughput for the three pipelines in this repo:

- **OCR** (`mac-ocr`) — Apple **Vision** framework (`VNRecognizeTextRequest`)
- **AI file naming** (`name-file`) — Apple **FoundationModels** on-device LLM
- **Metadata extraction** (`extract-metadata`) — FoundationModels, schema-constrained JSON

All numbers are fully on-device, no network.

> Example outputs below use synthetic/placeholder values, not data from any real
> document.

## Machine

| | |
|---|---|
| Chip | Apple M4 (4 performance + 6 efficiency cores) |
| Memory | 24 GB |
| OS | macOS 26.5.1 (build 25F80) |
| Toolchain | Swift 6.3.2, Command Line Tools (no Xcode) |
| Binaries | release build, native arm64 (`swift build -c release`) |

## Workload

- Test document: a **12-page** scanned mortgage recording (dense legal text).
- OCR: full 12-page PDF, `--format text`, output discarded; 3 runs each mode.
- Naming: page-1 OCR text (237 words) piped to `name-file`; 10 sequential runs.

## OCR — pages per minute

| Mode | Per run (12 pages) | Pages/sec | **Pages/min** |
|------|--------------------|-----------|---------------|
| `--accurate` (default) | 26.7 / 29.4 / 28.1 s | ~0.43 | **~25** |
| `--fast` | 7.83 / 7.84 / 7.91 s | ~1.53 | **~92** |

`--fast` is ~3.6× faster on this document. This PDF is worst-case dense legal text at high rasterization DPI; clean pages or lower DPI run faster. Throughput scales roughly linearly with page count — Vision execution is serialized in-process (one page at a time on the ANE).

## AI file naming — names per minute

Each `name-file` invocation is a **fresh process**: start-up + a new `LanguageModelSession` + one generation.

The model fills three labeled fields (party / type / ref) which are assembled
into `<party>-<type>-<ref>`. Greedy decoding makes output deterministic.

| Mode | Per name | Names/min | Output shape |
|------|----------|-----------|--------------|
| Single (one process per doc) | ~1.9 s | ~32 | `‹party›-‹type›-‹ref#›` (e.g. `acme-invoice-10432`) |
| `--batch`, sequential | ~1.33 s | ~45 | same (identical every run) |
| `--batch`, concurrency 2 (default) | ~1.15 s | ~52 | same |

- Single mode pays the ~0.7 s model warmup on every invocation.
- Batch loads the model once (`prewarm()`); only the first document pays warmup.
- Naming two documents at once overlaps ~15%. **The default batch concurrency is
  2** (multi-file mode too); set `NAME_FILE_CONCURRENCY` to override.

### Performance experiments

Measured on the 16-doc corpus to find what actually moves the needle:

| Lever | Effect | Verdict |
|-------|--------|---------|
| Concurrency 1 → 2 | 1.33 → 1.15 s/name | **shipped** (free, no quality cost) |
| Concurrency 2 → 4 → 8 | no further gain | heavy compute serializes past 2 |
| Input clip 1000 → 350 chars | ~11 % faster | **rejected** — misses primary parties lower in the page (e.g. page 2's borrower at char 699) |
| `maximumResponseTokens` 64 → 24 | no change | greedy stops at ~30 tokens regardless; cap is a ceiling, not a target |

**Conclusion:** this is a fixed on-device model with a hard decode floor (~30
output tokens at ~40 tok/s ≈ 1.1 s). There is no dramatic speedup available —
the one free win (concurrency 2, ~13–16 %) is now the default. Faster than that
would require generating fewer tokens, which trades away the structured
selection that keeps names accurate.

Output is stable and correct — it picks the named borrower, not the recording
clerk in the letterhead, by extracting a labeled `party` field with an explicit
exclusion for clerks/recorders.

## Metadata extraction — `extract-metadata`

Same on-device model, but constrained to a caller-supplied JSON schema (built at
runtime via `DynamicGenerationSchema`) so the output is guaranteed-valid JSON.
Measured with a 5-field schema (string/number/date/party/ref).

| Mode | Per doc | Docs/min |
|------|---------|----------|
| Single (one process per doc) | ~2.7 s | ~22 |
| `--batch`, sequential | ~2.0 s | ~30 |
| `--batch`, concurrency 2 (default) | ~1.84 s | ~33 |

Slower than `name-file` (~1.15 s) for two reasons, both inherent to the larger
job: a bigger input clip (4000 vs 1000 chars — metadata fields can sit anywhere
in a document) and more output tokens (a full JSON object vs a short slug).
Decode of the JSON still dominates, so per-doc time scales with the number and
size of schema fields. Concurrency 2 is the default here too.

Reuses `MacAIKit` (model availability, `mapConcurrent`, `fixWordOcr`,
deterministic options) shared with `name-file`. Numbers are emitted cleanly
(`11.89`, not `11.890000000000001`) and OCR glitches in string values are
repaired case-aware (`L1GHTHOUSE C0NSULTING` → `LIGHTHOUSE CONSULTING`).

## Combined: full PDF → one file name

OCR page 1 + generate a name end-to-end:

- `--accurate`: ~2.2 s page-1 OCR + ~1.8 s naming ≈ **~4 s/document**
- `--fast`: ~0.65 s page-1 OCR + ~1.8 s naming ≈ **~2.5 s/document**

(Naming only needs page 1, so OCR cost here is one page, not all twelve.)

## Caveats

- **Inference dominates naming, not warmup.** Batch + concurrency 2 cut per-name time to ~1.15 s; the residual is the on-device decode itself (~30 output tokens at ~40 tok/s), not process spawn or model load. See the experiments table above — clip size and token cap don't help, and concurrency saturates at 2. ~1.15 s/name is roughly the floor for this model on an M4.
- **Vision is serialized.** `mac-ocr` runs one page through the ANE at a time by design (parallel Vision calls contend for the ANE and degrade). Running multiple `mac-ocr` processes in parallel does **not** add throughput for that reason.
- Numbers are single-machine, single-document. Different hardware (M-series tier), thermal state, page complexity, and DPI will shift them.

## Reproduce

```bash
swift build -c release --product mac-ocr
swift build -c release --product name-file
PDF=path/to/your-scan.pdf   # any scanned PDF

# OCR pages/min (accurate vs fast)
for mode in "" "--fast"; do
  /usr/bin/time -p .build/release/mac-ocr "$PDF" $mode --format text >/dev/null
done

# Names/min — single mode (one process per doc)
.build/release/mac-ocr "$PDF" --format jsonl | head -1 \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['text'])" > /tmp/page1.txt
time (for i in $(seq 1 10); do .build/release/name-file < /tmp/page1.txt >/dev/null; done)

# Names/min — batch mode (one process, NUL-separated docs)
printf '%s\0%s\0%s\0%s\0%s' "$(cat /tmp/page1.txt)" "$(cat /tmp/page1.txt)" \
  "$(cat /tmp/page1.txt)" "$(cat /tmp/page1.txt)" "$(cat /tmp/page1.txt)" \
  | time .build/release/name-file --batch
```
