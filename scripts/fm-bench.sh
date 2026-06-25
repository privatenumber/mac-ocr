#!/bin/zsh
# Benchmark Apple Foundation Models throughput via the `fm` CLI.
#
# Measures decode tokens/sec by timing `fm respond` and counting the exact
# output tokens with `fm token-count`. Uses --greedy so output is
# deterministic and runs are directly comparable.
#
# Usage:
#   scripts/fm-bench.sh            # benchmark on-device "system" model
#   scripts/fm-bench.sh pcc        # benchmark Private Cloud Compute
#                                  # (run from an interactive Terminal —
#                                  #  PCC needs the logged-in GUI session)
#
# Note: PCC reports "not available in this context" when launched from a
# sandboxed/agent shell. Run it directly in Terminal.app.

set -e
MODEL="${1:-system}"
RUNS="${RUNS:-3}"
RETRIES="${RETRIES:-3}"            # retry transient PCC network failures
SHORT_PROMPT="${SHORT_PROMPT:-Reply with exactly one short sentence: what is Swift?}"
# Use a neutral technical topic: PCC's server-side safety layer false-fires on
# some innocuous long-form factual prompts (photosynthesis tripped it), and with
# --greedy that trip is deterministic. A programming/protocol topic is reliably
# clear. PCC long generations can also drop the connection ("A network failure
# occurred") on very long outputs, so PCC gets a shorter long-prompt.
if [[ "$MODEL" == "pcc" ]]; then
  LONG_PROMPT="${LONG_PROMPT:-Write a 3-paragraph explanation of how the HTTP protocol works.}"
else
  LONG_PROMPT="${LONG_PROMPT:-Write a detailed 6-paragraph explanation of how the HTTP protocol works, with specifics.}"
fi

# Run once. Echoes "<tokens> <seconds>", or "ERR <seconds>" with the model's
# stderr surfaced when the response is empty (quota/guardrail/timeout/error).
run_one() {
  local prompt="$1" out err rc t0 t1 toks dt attempt
  err=$(mktemp)
  for attempt in $(seq 1 $RETRIES); do
    t0=$(python3 -c 'import time;print(time.time())')
    # Disable errexit around the call: fm exits non-zero on network/quota/
    # guardrail/timeout failures, which would otherwise abort the whole script.
    set +e
    out=$(fm respond --model "$MODEL" --no-stream --greedy "$prompt" 2>"$err")
    rc=$?
    set -e
    t1=$(python3 -c 'import time;print(time.time())')
    dt=$(python3 -c "print(f'{$t1-$t0:.3f}')")
    if (( rc == 0 )) && [[ -n "${out//[[:space:]]/}" ]]; then break; fi
    echo "    .. attempt $attempt/$RETRIES failed (exit $rc): $(sed 's/\x1b\[[0-9;]*m//g' "$err" | tr '\n' ' ')" >&2
    sleep 2
  done
  if (( rc != 0 )) || [[ -z "${out//[[:space:]]/}" ]]; then
    rm -f "$err"; echo "ERR $dt"; return
  fi
  rm -f "$err"
  toks=$(print -r -- "$out" | fm token-count 2>/dev/null | tr -dc '0-9')
  echo "${toks:-ERR} $dt"
}

bench() {
  local label="$1" prompt="$2" sum_tok=0 sum_dt=0 n_ok=0 res tok dt tps
  echo "## $label"
  for i in $(seq 1 $RUNS); do
    res=$(run_one "$prompt")
    tok=${res% *}; dt=${res#* }
    if [[ "$tok" == "ERR" ]]; then
      echo "  run $i: FAILED after ${dt}s (see message above)"
      continue
    fi
    tps=$(python3 -c "print(f'{$tok/$dt:.1f}')")
    echo "  run $i: ${tok} tok in ${dt}s -> ${tps} tok/s"
    sum_tok=$(python3 -c "print($sum_tok+$tok)")
    sum_dt=$(python3 -c "print($sum_dt+$dt)")
    n_ok=$((n_ok+1))
  done
  if (( n_ok == 0 )); then
    echo "  AVG: n/a — all runs failed"; echo ""
    AVG_TOK=0; AVG_DT=0; return
  fi
  echo "  AVG: $(python3 -c "print(f'{$sum_tok/$sum_dt:.1f}')") tok/s (raw, includes startup+prefill)"
  echo ""
  AVG_TOK=$(python3 -c "print($sum_tok/$n_ok)")
  AVG_DT=$(python3 -c "print($sum_dt/$n_ok)")
}

echo "# fm benchmark — model=$MODEL, greedy, --no-stream, runs=$RUNS"
echo ""
# Warmup with retries — PCC can be transiently "unavailable in this context"
# right after a network failure (it cools down, then recovers).
warmed=0
for attempt in $(seq 1 $RETRIES); do
  if fm respond --model "$MODEL" --no-stream --greedy "Warmup." >/dev/null 2>&1; then
    warmed=1; break
  fi
  echo "warmup attempt $attempt/$RETRIES: '$MODEL' unavailable, retrying..." >&2
  sleep 5
done
(( warmed )) || { echo "Model '$MODEL' unavailable after $RETRIES attempts (PCC may be in a network/cooldown state — try again shortly)."; exit 1; }

bench "SHORT output" "$SHORT_PROMPT"
S_TOK=$AVG_TOK; S_DT=$AVG_DT

bench "LONG output" "$LONG_PROMPT"
L_TOK=$AVG_TOK; L_DT=$AVG_DT

echo "## Decode rate (slope: extra tokens / extra time, cancels fixed overhead)"
python3 -c "
st,sd,lt,ld=$S_TOK,$S_DT,$L_TOK,$L_DT
if min(st,lt)<=0 or (lt-st)<=0 or (ld-sd)<=0:
    print('  n/a — need both a short and a long successful run')
else:
    dt=lt-st; dd=ld-sd
    print(f'  short: {st:.0f} tok / {sd:.2f}s')
    print(f'  long : {lt:.0f} tok / {ld:.2f}s')
    print(f'  slope: {dt:.0f} extra tok / {dd:.2f}s = {dt/dd:.1f} tok/s decode')
    print(f'  fixed overhead: {sd - st/(dt/dd):.2f}s')
"
