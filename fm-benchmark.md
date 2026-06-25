# Benchmark — Apple Foundation Models via the `fm` CLI

On-device throughput for the **Apple Foundation Model** in macOS 27, measured
directly through Apple's `fm` command-line tool (not this repo's Swift binaries),
on **this machine** on **2026-06-25**.

Unlike [`benchmark-m1-max.md`](benchmark-m1-max.md), which estimated tokens as
`chars ÷ 4` on the output of the `name-file`/`extract-metadata` binaries, these
numbers use the **exact token counts** reported by `fm token-count`, giving a
true decode-throughput figure.

## Machine

| | |
|---|---|
| Chip | Apple **M1 Max** (10 cores) |
| Memory | **64 GB** |
| OS | macOS **27.0** (build 26A5368g) |
| Toolchain | Swift **6.4** |
| Tool | `/usr/bin/fm` (Apple Foundation Models CLI) |

## Models

| Model | `fm` name | Status here |
|-------|-----------|-------------|
| On-device Apple Foundation Model | `system` | ✅ Available — benchmarked below |
| Private Cloud Compute | `pcc` | ⚠️ See [PCC note](#private-cloud-compute-pcc) |

## Methodology

- **Command:** `fm respond --model <m> --no-stream --greedy "<prompt>"`.
  `--greedy` makes generation deterministic, so repeated runs produce an
  identical token count and times are directly comparable.
- **Timing:** wall-clock around the `fm respond` process (`time.time()` before
  and after). This includes process startup + prompt prefill + decode.
- **Tokens:** the raw model output is piped to `fm token-count` for an **exact**
  output-token count — no `chars ÷ 4` estimation.
- **tok/s (raw):** `output_tokens ÷ wall_time`. This *understates* decode speed
  for short outputs because fixed startup/prefill overhead dominates.
- **tok/s (decode, slope):** run a short and a long prompt, then take
  `(long_tokens − short_tokens) ÷ (long_time − short_time)`. Subtracting the two
  cancels the fixed per-invocation overhead and isolates pure decode throughput.
- Each workload is run **3 times** after a warmup call; figures are the average.

---

## On-device (`system`) — results

| Workload | Output tokens | Wall time | tok/s (raw) |
|----------|--------------:|----------:|------------:|
| Short reply (1 sentence) | 18 | 0.65 s | **27.6** |
| Long reply (6 paragraphs) | 887 | 27.6 s | **32.1** |

Long prompt: *"Write a detailed 6-paragraph explanation of how the HTTP protocol
works, with specifics."* (Earlier runs used a photosynthesis prompt; it was
swapped because PCC's safety layer false-fires on it — see the [PCC
note](#private-cloud-compute-pcc).) Per-run consistency under `--greedy` was
within ±0.2 tok/s across all three runs of each workload (the 887-token long
output was byte-identical every run).

### Decode rate (slope method)

| | Tokens | Time |
|---|--------:|-----:|
| Short | 18 | 0.65 s |
| Long | 887 | 27.60 s |
| **Δ (decode)** | **+869** | **+26.95 s** |

> **Decode throughput ≈ 32.2 tok/s**, with **~0.09 s fixed overhead** per
> invocation (process startup + prompt prefill).

So on this M1 Max, the on-device Apple Foundation Model generates at roughly
**32 tokens per second**. The raw short-prompt figure (27.6 tok/s) is lower only
because the fixed overhead is a larger fraction of a sub-one-second run.

### vs. the older estimate

[`benchmark-m1-max.md`](benchmark-m1-max.md) reported ~10–16 tok/s for the
on-device path. That used `chars ÷ 4` token estimation on tiny outputs from the
Swift `name-file`/`extract-metadata` binaries, where per-call overhead dominated.
Measured against the real `fm` CLI with exact token counts, the model's actual
decode rate is **~32 tok/s** — the earlier number reflected overhead, not the
model's true generation speed.

---

## Private Cloud Compute (`pcc`)

### Availability is context-dependent

- In an **interactive Terminal** (launched from the macOS GUI, signed in to your
  Apple Account), `fm quota-usage` reports `PCC: ✓ Available`.
- From the **shell this agent spawns** (and any sandboxed/headless context), the
  same commands return `Error: PCC inference is not available in this context.`
  — the process lacks the authenticated login-session entitlement PCC requires.
  PCC therefore can only be benchmarked from a real Terminal session.

### Measured behaviour (M1 Max, this account/network)

PCC was benchmarked from an interactive Terminal. The **limiting factor is
reliability, not speed**:

| Workload | Result | tok/s (raw) |
|----------|--------|------------:|
| Short reply (26 tok) | ✅ consistent across 3 runs | **~44–48** |
| Long reply (~300–600 tok) | ❌ `Error: A network failure occurred` | n/a |

- **Short PCC generations are fast** — ~44–48 tok/s raw, *higher* than the
  on-device ~25 tok/s raw on the same short prompt (PCC runs a larger model on
  server hardware).
- **Long PCC generations fail** with `A network failure occurred. Please try
  again.` The connection drops before the larger output completes — observed for
  both the 6-paragraph (~600 tok) and 3-paragraph (~300 tok) prompts.
- **PCC goes intermittently unavailable.** After a network failure it returns
  `unavailable in this context` for a cooldown period, then recovers on its own.
  `fm quota-usage` reads `✓ Available` throughout, so this is **not** a quota
  limit and **not** a content guardrail (short prompts always pass).

Because long outputs don't complete reliably, a clean PCC **decode-rate (slope)**
number could not be captured on this network. The short-prompt figure (~46 tok/s)
includes fixed overhead and is an *upper-bound-ish* raw rate, not pure decode.

> **Bottom line for PCC here:** fast when it works, but long generations are
> network-limited. For sustained/long outputs on this setup, the **on-device
> model is the more reliable path**; PCC is best for short requests.

To retry PCC (it improves when the network is stable), the script auto-retries
network failures and uses a shorter long-prompt for PCC:

```bash
scripts/fm-bench.sh pcc
# tune if needed:
LONG_PROMPT='Write a 2-paragraph summary of how the HTTP protocol works.' \
  RETRIES=5 scripts/fm-bench.sh pcc
```

If a long PCC run completes, fill in its decode rate here:

| Workload | Output tokens | Wall time | tok/s |
|----------|--------------:|----------:|------:|
| Short | 26 | ~0.55 s | ~46 (raw) |
| Long | _network-limited_ | _—_ | _—_ |
| **Decode (slope)** | _TBD_ | _TBD_ | **_TBD_** |

---

## Summary

| Model | Backend | Throughput | Notes |
|-------|---------|-----------:|-------|
| `system` | On-device (M1 Max) | **~32 tok/s** decode (~0.09 s overhead/call) | reliable for any length |
| `pcc` | Private Cloud Compute | **~46 tok/s** raw on short prompts | long outputs network-limited; intermittently unavailable |

---

## Reproduce

```bash
# On-device (works anywhere the system model is available):
scripts/fm-bench.sh            # or: scripts/fm-bench.sh system

# Private Cloud Compute (run from an interactive Terminal, not an agent shell):
scripts/fm-bench.sh pcc

# Sanity checks:
fm available                   # which models are usable in this context
fm quota-usage                 # PCC quota / availability
fm token-count 'Hello world'   # exact token count for a string
```

The script ([`scripts/fm-bench.sh`](scripts/fm-bench.sh)) times `fm respond`
around short and long greedy prompts, counts exact output tokens with
`fm token-count`, and prints both raw and slope-based tok/s.
