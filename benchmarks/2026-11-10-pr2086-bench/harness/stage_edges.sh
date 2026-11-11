#!/usr/bin/env bash
# Edge cases on a running 1P1D pair with the switch on (edges.sh E1-E3; the kill/restart cases E4/E5 need a host-level
# restart and do not run on CDK pods): E1 single-request output equivalence (recall vs recompute, 16 sessions),
# E2 concurrent recalls after a prefill-only flush and client aborts mid-recall, E3 flush of both engines under load.
source "$HARNESS/common.sh"
fresh_run
P0=$(awk '{print $1}' <<< "$PREFILL_URLS"); D0=$(awk '{print $1}' <<< "$DECODE_URLS")
EDGES=${EDGES:-E1,E2,E3,E6}; want() { case ",$EDGES," in *,$1,*) return 0;; *) return 1;; esac; }
log "EDGES start ($RUN, cases $EDGES): $(health) $(exc)"
wipe || exit 1
if want E1; then
log "E1 integrity: recalled outputs must equal a recompute after a flush"
timeout 5400 $PY $HARNESS/victim_integrity.py --lb $(lb_pin 0 0) --flush $P0 $D0 --tokenizer $TOK --prompts $PROMPTS --sessions ${E1_SESSIONS:-16} --prefix 131072 --new 8192 --concurrency ${E1_CONC:-1} --probe-phases ${E1_PROBE_PHASES:-fill,settle} --out $OUT/${RUN}_integrity.json > $OUT/${RUN}_integrity.out 2>&1
log "E1 rc=$? $(grep -E '^SUMMARY' $OUT/${RUN}_integrity.out | cut -c1-700)"; log "E1 after: $(health) $(exc)"
fi
if want E2; then wipe || log "wipe FAILED"
log "E2 stress: concurrent recalls after a prefill-only flush, and client aborts mid-recall"
timeout 3600 $PY $HARNESS/spill_stress.py --lb $(lb_pin 0 0) --prefill-url $P0 --decode-url $D0 --tokenizer $TOK --prompts $PROMPTS --prefix 131072 --new 8192 --sessions 6 --phases concurrent,abort --flush-targets prefill --phase-timeout 900 --out $OUT/${RUN}_stress.json > $OUT/${RUN}_stress.out 2>&1
log "E2 rc=$? $(tail -3 $OUT/${RUN}_stress.out | tr '\n' ' ' | cut -c1-600)"; log "E2 after: $(health) $(exc)"
fi
if want E3; then wipe || log "wipe FAILED"
log "E3 flush under load: flush both engines 30 s into a static run"
( static e3_flush_load 8 $(lb_pin 0 0) $P0 $D0 > $OUT/${RUN}_e3.res ) & bg=$!
sleep 30; fa=$(curl -s -m 60 -o /dev/null -w '%{http_code}' -X POST $P0/flush_cache); fv=$(curl -s -m 60 -o /dev/null -w '%{http_code}' -X POST $D0/flush_cache)
wait $bg; log "E3 flush codes prefill=$fa decode=$fv (400 = refused while transfers are in flight, as designed); $(cat $OUT/${RUN}_e3.res); $(health) $(exc)"
fi
if [ "${HYBRID:-false}" = true ] && want E6; then
  wipe || log "wipe FAILED"
  log "E6 hybrid window edges (H5) + transfer correctness: 5 edge-shaped returns, each recomputed after a flush"
  timeout 5400 $PY $HARNESS/hybrid_window_edges.py --lb $(lb_pin 0 0) --flush $P0 $D0 --tokenizer $TOK --prompts $PROMPTS --sessions ${E1_SESSIONS:-16} --prefix 131072 --new 8192 --page ${PAGE_SIZE:-64} --out $OUT/${RUN}_window_edges.jsonl > $OUT/${RUN}_window_edges.out 2>&1
  log "E6 rc=$? $(grep -E '^SUMMARY' $OUT/${RUN}_window_edges.out | cut -c1-900)"; log "E6 after: $(health) $(exc)"
fi
sleep 60; evidence | tee -a "$OUT/evidence.txt"
log "EDGES DONE ($RUN): $(health) $(exc)"
