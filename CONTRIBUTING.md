# Contributing

Project posture, development setup, and conventions for working on `mac-ocr`.

## Posture

This project follows [semantic versioning](https://semver.org/) via [semantic-release](https://github.com/semantic-release/semantic-release); commit message types drive the version bump automatically.

- **Semver is the deprecation strategy.** Breaking changes (flag removals, output schema changes) require a `BREAKING CHANGE:` footer and trigger a major bump. Additive changes (new flags) are non-breaking minors.
- **Correctness over speed.** Read the docs, trace behavior end-to-end, verify against a real input — then decide.
- **Developer experience is the product.** If a command feels clunky, redesign it.

## What lives where

Two deliverables ship from this repo:

1. **The CLI** — a Swift binary (`Sources/`) built on Apple's Vision framework.
2. **The Node.js API** (`src/`) — a typed wrapper that spawns the bundled binary; published to npm as the same package (`dist/` via pkgroll).

User-facing docs: [README.md](README.md), [docs/CLI.md](docs/CLI.md), [docs/NODE.md](docs/NODE.md), and the agent skill in [skills/mac-ocr/SKILL.md](skills/mac-ocr/SKILL.md). All four must be updated for user-facing changes.

## Requirements

- macOS 10.15+ (deployment target; development uses a current Xcode)
- A recent full Xcode (not just Command Line Tools — `swift test` uses the Swift Testing framework) with a Swift 6 toolchain (`Package.swift` is tools 6.0, Swift 6 language mode with strict concurrency)
- Node.js (see `.nvmrc`) + pnpm — for the Node API, its tests, linting, and the build/publish pipeline

## Development

### Build and run

```sh
swift build
swift run mac-ocr receipt.jpg
swift run mac-ocr scan.pdf --format jsonl
swift run mac-ocr searchable-pdf scan.pdf -o out.pdf
swift run mac-ocr --help
```

### Test

```sh
swift test --no-parallel # Swift suites (spawn .build/debug/mac-ocr)
pnpm install
pnpm test:node           # Node API suites (manten) — builds and copies the debug binary to bin/mac-ocr first
pnpm typecheck
pnpm lint                # lintroll (TS) + swift format lint
```

**Why `--no-parallel`?** Swift Testing runs suites in parallel by default. Integration suites spawn the `mac-ocr` subprocess while engine suites call Vision in-process; Vision pins the Apple Neural Engine (a shared resource), so concurrent suites cause ANE contention and sandbox resource kills. Serialization is enforced two ways:

1. **`@Suite(.serialized)`** on every top-level suite.
2. **`VisionGate`** (`Tests/mac-ocrTests/VisionGate.swift`) — a process-wide semaphore that `TestSupport.run()` acquires before spawning the binary, serializing Vision access across suite boundaries.

Run one suite: `swift test --no-parallel --filter SearchablePDFTests`

**Schema snapshots:** the JSON/JSONL output schema and the fd-3 error envelope are pinned by golden files (`Tests/mac-ocrTests/Snapshots/`). A deliberate schema change regenerates them with `MAC_OCR_UPDATE_SNAPSHOTS=1 swift test --no-parallel --filter SchemaSnapshotTests` — the golden diff in review *is* the schema change. Remember the `BREAKING CHANGE:` footer.

**Node API tests.** Main-thread `ocr()` uses `src/service/` and is covered by `Tests/specs/service/`. One-shot argument handling, environment forwarding, stream parsing, and exit classification are covered by scripted binaries in `Tests/specs/wrapper.ts`. `importWrapper` (`Tests/utils.ts`) copies `src/` into a temp fixture with a shim at `bin/mac-ocr`, so no Vision is involved.

### Release build (universal binary)

```sh
pnpm build
```

Runs `scripts/write-version.mjs` (injects the package version into `Sources/MacOcrCore/Version.swift`), builds a universal (arm64 + x86_64) release binary into `bin/mac-ocr`, and bundles the Node API into `dist/` with pkgroll. Also runs via the `prepack` hook before `npm publish`, alongside `clean-pkg-json`.

The Swift build is tuned for binary size (the package ships this binary over npm): `-Xswiftc -Osize` (runtime is Vision/ANE-bound, so Swift glue speed is irrelevant), `-Xlinker -dead_strip`, and a final `strip -rSTx` (removes the nlist symbol table — ~1.1 MB per slice — but not the `__swift5_*` reflection metadata ArgumentParser relies on). Together: ~4.1 MB → ~1.8 MB universal.

## Project structure

```
Sources/MacOcrCore/        # pure core target; no ArgumentParser dependency
├── Engines/               # recognizeText + OCREngine (serialized Vision entry)
├── SearchablePDF/         # vector-preserving writer + per-word invisible text layer
├── Geometry/              # BoundingBox + TL↔BL coordinate conversions
├── Input/                 # image/PDF/stdin/URL loading, rasterization, auto-DPI
├── Output/                # result envelope, formats, output strategy + routing
└── Runtime/               # VisionSession/VisionRuntime/BatchRunner, errors

Sources/MacOcrCLI/         # ArgumentParser target; owns the command-line surface
├── RootCommand.swift      # OCR is the default subcommand; fd-3 error envelopes
├── Commands/              # OCRCommand, SearchablePDFCommand, LanguagesCommand
└── Options/               # OcrCommandOptions, RecognitionOptions (shared flags), validation

Sources/mac-ocr/main.swift # thin executable; delegates to MacOcr.run(arguments:)

src/                       # Node.js API (published as dist/ via pkgroll)
Tests/mac-ocrTests/        # Swift Testing suites (TestSupport / VisionGate / Snapshots)
Tests/specs/ + Tests/index.ts  # Node API suites (manten)
Tests/fixtures/            # see Tests/fixtures/README.md for provenance
docs/                      # CLI.md + NODE.md references (shipped to npm)
skills/                    # agent skill (shipped to npm via skills-npm)
```

### Architecture

- **Pure core.** `MacOcrCore` operates on `VisionSession`/`CGImage` plus typed options; no flag parsing. Commands call core; core never calls commands.
- **Serialized Vision.** All recognition routes through the `VisionRuntime` actor (`OCREngine.run`). Its closure is deliberately synchronous — see the warning on `VisionRuntime` before changing this.
- **One runner.** `BatchRunner` owns source opening, PDF page iteration, serial execution, and fail-soft error aggregation (`ErrorSink`); the per-page operation and the output shape (`OutputStrategy`) are injected. `searchable-pdf` drives `SearchablePDF.render(...)` directly because its output is one binary PDF per input rather than per-page analysis.
- **Three commands.** `RootCommand` registers `OCRCommand` (default — `mac-ocr photo.png` just works), `SearchablePDFCommand`, and `LanguagesCommand`. Shared recognition flags live in the `RecognitionOptions` option group so the commands cannot drift.
- **Node API.** `src/ocr.ts` routes main-thread `ocr()` through `src/service/`; worker-thread calls and the other APIs use the one-shot process path. One-shot calls use JSONL output and fd-3 error envelopes. The service owns its framed protocol, FIFO staging queue, cancellation watchdog, and cleanup. Passwords never enter `argv`: service calls use framed requests, while one-shot calls use `MAC_OCR_PDF_PASSWORD`. The executable's `--service` switch is internal: `main.swift` handles it before ArgumentParser, so it stays out of public help and shell completions.

## CI/CD

Workflows live in [.github/workflows/](.github/workflows/) — `test.yml` (build, Swift tests, typecheck, lint, Node tests) and `release.yml` (universal build + semantic-release publish). Note: this development repo is private and runs no CI; the workflows are kept current for the public release repo.

## Commits

[semantic-release](https://github.com/semantic-release/semantic-release) with the Angular preset:

| Prefix | Release |
|--------|---------|
| `feat:` | minor |
| `fix:` / `perf:` | patch |
| `docs:`, `chore:`, `refactor:`, `test:`, `build:`, `ci:` | no release |

Breaking changes use a `BREAKING CHANGE:` footer (the `feat!:` syntax does **not** trigger a major under the default Angular preset):

```
feat(ocr): restructure result schema

BREAKING CHANGE: the flat `file` field is replaced by a tagged `source` union.
```

## Pre-commit checklist

1. `swift build` clean
2. `swift test --no-parallel` passes
3. `pnpm test:node` passes
4. `pnpm typecheck` and `pnpm lint` clean
5. `git diff` reviewed
6. Commit message follows the Angular convention
7. `README.md` + `docs/` + `skills/mac-ocr/SKILL.md` updated for user-facing changes
