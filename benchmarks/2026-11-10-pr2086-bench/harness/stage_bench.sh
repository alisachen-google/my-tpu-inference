#!/usr/bin/env bash
# PR 2086 1P1D campaign (write-back or write-through, chosen by the recipe's WRITE_POLICY; SWITCH on/off is the
# server-side arm): the PR 1798 workload at 128k+8k, caches wiped before every point.
#   recall ladder  N = 8 12 16 sessions: fill phase, settle, return phase (each phase its own POINT, so the
#                  return's prefill-side hit, throughput and latency are bracketed exactly)
#   static ladder  K = 4 8 12 16 documents (3 visits each, 256 output tokens)
#   mixed sizes    long 128k+8k (8 docs x 3 visits, concurrency 4) with short 32k+4k (48 sessions, concurrency 8)
#   integrity      single-request output equivalence, 16 sessions, recall one at a time vs a recompute after a flush
# then the offload counters and rank consistency from both server logs.
source "$HARNESS/common.sh"
fresh_run
P0=$(awk '{print $1}' <<< "$PREFILL_URLS"); D0=$(awk '{print $1}' <<< "$DECODE_URLS")
RECALL_POINTS=${RECALL_POINTS:-"8 12 16"}; STATIC_POINTS=${STATIC_POINTS:-"4 8 12 16"}
DO_MIXED=${DO_MIXED:-true}; DO_INTEGRITY=${DO_INTEGRITY:-true}
log "BENCH start ($RUN, policy ${WRITE_POLICY:-?}, switch ${SWITCH:-?}): $(health) $(exc)"
for n in $RECALL_POINTS; do
  wipe || { log "BENCH wipe FAILED before recall $n"; exit 1; }
  log "recall $n fill: $(recall recall_${n}_fill $n fill $LB 5 131072 8192 4 p0d0)"
  sleep ${SETTLE:-20}
  log "recall $n return: $(recall recall_${n}_ret $n recall $LB 5 131072 8192 4 p0d0)"
  log "after recall $n: $(health) $(exc)"
done
for k in $STATIC_POINTS; do
  wipe || { log "BENCH wipe FAILED before static $k"; exit 1; }
  log "static $k docs: $(static static_$k $k $LB $P0 $D0 p0d0)"
  log "after static $k: $(health) $(exc)"
done
if [ "$DO_MIXED" = true ]; then
  wipe || log "BENCH wipe FAILED before mixed"
  snap "$OUT/${RUN}_mixed.m0"; t0=$(now)
  $PY $HARNESS/static_reuse.py --prefixes 8 --visits 3 --prefix 131072 --new 8192 --out-tokens 256 --concurrency 4 --seed 17 --run $RUN --label mixed_long --tokenizer $TOK --prompts $PROMPTS --lb $LB --prefill-url $P0 --decode-url $D0 --out $OUT/${RUN}_mixed_long.jsonl > $OUT/${RUN}_mixed_long.out 2>&1 & bg=$!
  $PY $HARNESS/victim_recall.py --sessions 48 --prefix 32768 --new 4096 --out-tokens 16 --concurrency 8 --seed 21 --run $RUN --phase both --settle 20 --label mixed_short --tokenizer $TOK --prompts $PROMPTS --lb $LB --out $OUT/${RUN}_mixed_short.jsonl > $OUT/${RUN}_mixed_short.out 2>&1
  wait $bg
  t1=$(now); snap "$OUT/${RUN}_mixed.m1"
  for s in mixed_long mixed_short; do cp "$OUT/${RUN}_mixed.m0" "$OUT/${RUN}_$s.m0"; cp "$OUT/${RUN}_mixed.m1" "$OUT/${RUN}_$s.m1"; done
  log "mixed long (128k+8k, 8 docs x 3, conc 4): $(strict $OUT/${RUN}_mixed_long.jsonl); $(point mixed_long all p0d0 "$t0" "$t1" mixed)"
  log "mixed short (32k+4k, 48 sessions, conc 8): $(strict $OUT/${RUN}_mixed_short.jsonl); $(point mixed_short all p0d0 "$t0" "$t1" mixed)"
  log "after mixed (the prefill-side hit above spans both streams; the window is the whole mixed block): $(health) $(exc)"
fi
if [ "$DO_INTEGRITY" = true ]; then
  wipe || log "BENCH wipe FAILED before integrity"
  log "integrity: 16 sessions, recall one request at a time, outputs vs a recompute after a flush of both engines"
  timeout 5400 $PY $HARNESS/victim_integrity.py --lb $LB --flush $P0 $D0 --tokenizer $TOK --prompts $PROMPTS --sessions ${INTEGRITY_SESSIONS:-16} --prefix 131072 --new 8192 --concurrency 1 --probe-phases fill,settle --out $OUT/${RUN}_integrity.json > $OUT/${RUN}_integrity.out 2>&1
  log "integrity rc=$? $(grep -E '^SUMMARY' $OUT/${RUN}_integrity.out | cut -c1-900)"
  log "after integrity: $(health) $(exc)"
fi
sleep 60; evidence | tee -a "$OUT/evidence.txt"
log "BENCH DONE ($RUN): $(health) $(exc)"
