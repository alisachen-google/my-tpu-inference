#!/usr/bin/env bash
# A5: 2P2D with sticky routes (fill via p0/d0, return via the other prefill, the other decode, both) and random
# routing, as goal_baseline.sh's 2P2D block (same seeds and sizes). SWITCH on/off is the server-side arm; RUN names
# follow compare_layouts.py (g1992b_2p2d_1 / g1992b_2p2d_off_1).
source "$HARNESS/common.sh"
fresh_run
P0=$(awk '{print $1}' <<< "$PREFILL_URLS"); D0=$(awk '{print $1}' <<< "$DECODE_URLS")
log "2P2D start ($RUN): $(health) $(exc)"
for p in 0 1; do for d in 0 1; do log "pinned lb p$p d$d $(lb_pin $p $d) health=$(hc $(lb_pin $p $d)/health)"; done; done
wipe || exit 1
log "2P2D fill (p0,d0) 12 sessions: $(recall y2_fill 12 fill $(lb_pin 0 0) 51)"
log "2P2D return (p1,d0) other prefill, same decode: $(recall y2_b_v7 12 recall $(lb_pin 1 0) 51)"
log "2P2D return (p0,d1) same prefill, other decode: $(recall y2_a_g 12 recall $(lb_pin 0 1) 51)"
log "2P2D return (p1,d1) other prefill, other decode: $(recall y2_b_g 12 recall $(lb_pin 1 1) 51)"
log "2P2D after sticky: $(health) $(exc)"
wipe || log "wipe FAILED before random"
log "2P2D random prefill and decode, 16 sessions: $(recall y1_recall 16 both $LB 5)"
log "2P2D after random: $(health) $(exc)"
if [ "${STATIC_DOCS:-0}" != 0 ]; then wipe; log "2P2D static ${STATIC_DOCS} docs via random lb: $(static y3_static $STATIC_DOCS $LB $P0 $D0)"; fi
if [ "${STRESS:-false}" = true ]; then wipe
  timeout 3600 $PY $HARNESS/spill_stress.py --lb $LB --prefill-url $P0 --decode-url $D0 --tokenizer $TOK --prompts $PROMPTS --prefix 131072 --new 8192 --sessions 6 --phases concurrent,abort --flush-targets prefill --phase-timeout 900 --out $OUT/${RUN}_stress.json > $OUT/${RUN}_stress.out 2>&1
  log "2P2D C1 stress rc=$? $(tail -3 $OUT/${RUN}_stress.out | tr '\n' ' ' | cut -c1-500); $(health) $(exc)"; fi
sleep 60; evidence | tee -a "$OUT/evidence.txt"
log "2P2D DONE ($RUN): $(health) $(exc)"
