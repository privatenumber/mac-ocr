# Benchmark — Apple M1 Max

On-device and cloud throughput for the pipelines in this repo, measured on **this machine** on **2025-06-24**.

| Pipeline | Tool | Backend |
|----------|------|---------|
| OCR | `mac-ocr` | Apple Vision (`VNRecognizeTextRequest`) |
| File naming | `name-file` | FoundationModels on-device or Private Cloud Compute |
| Metadata extraction | `extract-metadata` | FoundationModels on-device or Private Cloud Compute |

## Machine

| | |
|---|---|
| Chip | Apple **M1 Max** (10 cores) |
| Memory | **64 GB** |
| OS | macOS **27.0** (build 26A5368g) |
| Toolchain | Swift **6.4** |
| Binaries | `swift build -c release` (native arm64) |

## Methodology

- **OCR:** repo test fixtures in `Tests/fixtures/` (small synthetic pages — mostly “Hello World”). Each configuration run **3 times**; times below are typical `real` wall-clock from `/usr/bin/time -p`.
- **AI:** synthetic text documents (not OCR output) to avoid Vision stderr noise in piped workloads:
  - **Naming:** `/tmp/synthetic-mortgage.txt` (~90 words, borrower + deed-of-trust fields)
  - **Metadata:** `/tmp/synthetic-invoice.txt` (5-field JSON schema)
- **Tokens/sec:** FoundationModels does not expose token counts in the CLI. **Output tok/s** below is `estimated_output_tokens ÷ generation_time`, where tokens are estimated as `chars ÷ 4` on the model’s raw output (naming reply or JSON). This measures **decode throughput of the answer**, not prompt tokens or time-to-first-token.
- **Cloud:** `--cloud` uses `PrivateCloudComputeLanguageModel`. Binaries were signed with `com.apple.developer.private-cloud-compute`, but **cloud runs terminated immediately (SIGKILL)** with both ad-hoc and Apple Development identities — a provisioning profile whose App ID enables Private Cloud Compute is required. Cloud numbers are marked **N/A** on this setup.

> **Fixture caveat:** OCR fixtures are tiny (1–3 pages, minimal text). They show relative **accurate vs `--fast`** speed on this chip, but are **much faster** than dense real scans. For a 12-page legal mortgage on an M4, see [`benchmark.md`](benchmark.md) (~25 pages/min accurate). Expect proportionally lower absolute OCR throughput on M1 Max for the same heavy document.

---

## OCR — total time & pages per minute

| Input | Mode | Total time | Pages | sec/page | **pages/min** |
|-------|------|------------|-------|----------|---------------|
| `document-photo.png` (1 pg) | accurate | **0.29 s** | 1 | 0.29 | ~207 |
| `document-photo.png` (1 pg) | `--fast` | **0.12 s** | 1 | 0.12 | ~500 |
| `scanned-200dpi.pdf` (1 pg) | accurate | **0.21 s** | 1 | 0.21 | ~286 |
| `scanned-200dpi.pdf` (1 pg) | `--fast` | **0.11 s** | 1 | 0.11 | ~545 |
| `multipage.pdf` (3 pg) | accurate | **0.42 s** | 3 | 0.14 | **~429** |
| `multipage.pdf` (3 pg) | `--fast` | **0.16 s** | 3 | 0.053 | **~1,130** |

`--fast` is **~2.4–2.6×** faster than accurate on these fixtures.

Vision logged E5 bundle warnings on this macOS 27 beta build (`TextRecognition.framework`); OCR still completed successfully.

---

## `name-file` — on-device (local model)

Workload: synthetic mortgage text → slug `lighthouse-consulting-llc-deed-of-trust-2024-ml-00891`.

| Mode | Total time | Notes |
|------|------------|-------|
| Single (fresh process), run 1 | **2.92 s** | includes model load / warmup |
| Single, runs 2–5 (steady) | **1.91–1.97 s** | ~**1.94 s** typical |
| `--batch` × 5 (one process) | **7.30 s** | **1.46 s** / document |
| OCR page + name (multipage PDF) | **1.86 s** | 3-page OCR + one name |

**Output throughput (steady single run):**

| Metric | Value |
|--------|-------|
| Raw model reply | 3 lines (`party` / `type` / `ref`) |
| Estimated output tokens | ~**19** |
| Generation time | **1.95 s** |
| **Output tok/s** | **~9.7** |

For comparison, [`benchmark.md`](benchmark.md) reports ~**1.15 s**/name and ~**40 output tok/s** on an **M4** with a longer real OCR excerpt — the M1 Max on-device model is roughly **~40% slower** per name on this workload.

---

## `name-file` — Private Cloud Compute

| Mode | Total time | Output tok/s |
|------|------------|--------------|
| All modes | **N/A** | **N/A** |

Could not measure: process exits immediately after `--cloud` (SIGKILL), even with `com.apple.developer.private-cloud-compute` entitlement and Apple Development code signing. Needs a **provisioning profile** tied to an App ID with Private Cloud Compute enabled (see [`docs/PrivateCloudCompute.entitlements`](docs/PrivateCloudCompute.entitlements)).

---

## `extract-metadata` — on-device (local model)

Workload: synthetic invoice, 5-field schema (`vendor`, `customer`, `invoice_number`, `total`, `date`).

| Mode | Total time | Notes |
|------|------------|-------|
| Single, run 1 | **3.30 s** | warmup |
| Single, runs 2–5 (steady) | **2.18–2.24 s** | ~**2.21 s** typical |
| `--batch` × 3 | **5.69 s** | **1.90 s** / document |

**Output throughput (steady single run):**

| Metric | Value |
|--------|-------|
| JSON output size | 139 chars |
| Estimated output tokens | ~**35** |
| Generation time | **2.21 s** |
| **Output tok/s** | **~15.8** |

(Mortgage-shaped text triggered a “May contain sensitive content” guardrail for metadata extraction; invoice text succeeded.)

[`benchmark.md`](benchmark.md) M4 reference: ~**1.84 s**/doc batch, ~33 docs/min — again, M1 Max is slower on this schema size.

---

## `extract-metadata` — Private Cloud Compute

| Mode | Total time | Output tok/s |
|------|------------|--------------|
| All modes | **N/A** | **N/A** |

Same cloud signing / provisioning limitation as `name-file`.

---

## Combined pipeline (OCR → name)

| Step | Time |
|------|------|
| `mac-ocr multipage.pdf` + `name-file --device` (end-to-end) | **1.86 s** |

On trivial 3-page fixtures, OCR is a small fraction of total time; on a dense 12-page scan, OCR dominates (see [`benchmark.md`](benchmark.md): ~4 s/document accurate OCR page-1 + naming on M4).

---

## Summary

| Workload | Backend | Total time | Throughput |
|----------|---------|------------|------------|
| OCR 3-page PDF | Vision accurate | **0.42 s** | ~**429 pages/min** (trivial text) |
| OCR 3-page PDF | Vision `--fast` | **0.16 s** | ~**1,130 pages/min** (trivial text) |
| `name-file` | On-device | **~1.94 s** | ~**31 names/min**; **~10 output tok/s** |
| `name-file` | Cloud | N/A | requires PCC provisioning profile |
| `extract-metadata` (5 fields) | On-device | **~2.21 s** | ~**27 docs/min**; **~16 output tok/s** |
| `extract-metadata` | Cloud | N/A | requires PCC provisioning profile |

**Bottom line:** On this **M1 Max / 64 GB** Mac, local OCR on tiny fixtures is very fast; the **on-device FoundationModels** path is the bottleneck for naming (~2 s) and metadata (~2.2 s), at roughly **10–16 estimated output tokens/sec**. Cloud (PCC) could not be benchmarked here without a properly provisioned signed build.

---

## Reproduce

```bash
swift build -c release --product mac-ocr --product name-file --product extract-metadata

# OCR
/usr/bin/time -p .build/release/mac-ocr Tests/fixtures/multipage.pdf --format text >/dev/null
/usr/bin/time -p .build/release/mac-ocr Tests/fixtures/multipage.pdf --fast --format text >/dev/null

# name-file (device) — use synthetic mortgage text
/usr/bin/time -p .build/release/name-file --device < /tmp/synthetic-mortgage.txt

# extract-metadata (device) — invoice schema
/usr/bin/time -p .build/release/extract-metadata --device --schema /tmp/schema-invoice.json \
  < /tmp/synthetic-invoice.txt

# Cloud (only after Developer ID + PCC provisioning profile signing):
# codesign --force --options runtime \
#   --entitlements docs/PrivateCloudCompute.entitlements \
#   --sign "Developer ID Application: …" \
#   .build/release/name-file
# .build/release/name-file --cloud < /tmp/synthetic-mortgage.txt
```

Synthetic workloads used for AI timings:

```text
# /tmp/synthetic-mortgage.txt — borrower Lighthouse Consulting LLC, ref 2024-ML-00891
# /tmp/synthetic-invoice.txt   — vendor Lighthouse Consulting LLC, INV-2024-10432, $13,500
```
