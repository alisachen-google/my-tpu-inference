#!/usr/bin/env bash
# Sticky-route and random cases of one P/D layout, as goal_baseline.sh / compare_layouts.py (same seeds, 128k+8k
# sessions, 16 output tokens). LAYOUT is 1p1d, 1p2d, 2p1d or 2p2d; lb_pin P D is the mini-lb pinned to that pair,
# $LB the random one. SWITCH on/off is the server-side arm; RUN names follow compare_layouts.py.
source "$HARNESS/common.sh"
fresh_run
P0=$(awk '{print $1}' <<< "$PREFILL_URLS"); D0=$(awk '{print $1}' <<< "$DECODE_URLS")
log "LAYOUT $LAYOUT start ($RUN): $(health) $(exc)"
for u in $PREFILL_URLS $DECODE_URLS; do log "pins: $(for p in $(seq 0 $((NP-1))); do for d in $(seq 0 $((ND-1))); do printf 'p%sd%s=%s ' $p $d $(hc $(lb_pin $p $d)/health); done; done)"; break; done
wipe || exit 1
case "$LAYOUT" in
  1p1d)
    log "1P1D sticky fill (p0,d0) 12 sessions: $(recall z2_fill 12 fill $(lb_pin 0 0) 51)"
    log "1P1D sticky return (p0,d0): $(recall z2_recall 12 recall $(lb_pin 0 0) 51)"
    log "1P1D after sticky: $(health) $(exc)"; wipe || log "wipe FAILED"
    log "1P1D 16 sessions fill+recall via lb: $(recall z1_recall 16 both $LB 5)"
    ;;
  1p2d)
    log "1P2D sticky: 8 sessions pinned to decode 0: $(recall w2_d1 8 both $(lb_pin 0 0) 21)"
    log "1P2D sticky: 8 sessions pinned to decode 1: $(recall w2_d2 8 both $(lb_pin 0 1) 22)"
    log "1P2D after sticky: $(health) $(exc)"; wipe || log "wipe FAILED"
    log "1P2D random decode, 16 sessions: $(recall w1_recall 16 both $LB 5)"
    ;;
  2p1d)
    log "2P1D fill via prefill 0 (12 sessions): $(recall x2_fill 12 fill $(lb_pin 0 0) 31)"
    [ "${KEEPALIVE:-true}" = true ] && log "2P1D keep-alive on prefill 0 (24 short sessions, so it pushes the filled branches): $(keepalive $(lb_pin 0 0) x2_keepalive)"
    log "2P1D cross-prefill return via prefill 1: $(recall x2_recall_b 12 recall $(lb_pin 1 0) 31)"
    log "2P1D return via prefill 0 again: $(recall x2_recall_a 12 recall $(lb_pin 0 0) 31)"
    log "2P1D after sticky: $(health) $(exc)"; wipe || log "wipe FAILED"
    log "2P1D random prefill, 16 sessions: $(recall x1_recall 16 both $LB 5)"
    ;;
  2p2d)
    log "2P2D fill (p0,d0) 12 sessions: $(recall y2_fill 12 fill $(lb_pin 0 0) 51)"
    [ "${KEEPALIVE:-true}" = true ] && log "2P2D keep-alive on prefill 0 (24 short sessions, so it pushes the filled branches): $(keepalive $(lb_pin 0 0) y2_keepalive)"
    log "2P2D return (p1,d0) other prefill, same decode: $(recall y2_b_v7 12 recall $(lb_pin 1 0) 51)"
    log "2P2D return (p0,d1) same prefill, other decode: $(recall y2_a_g 12 recall $(lb_pin 0 1) 51)"
    log "2P2D return (p1,d1) other prefill, other decode: $(recall y2_b_g 12 recall $(lb_pin 1 1) 51)"
    log "2P2D after sticky: $(health) $(exc)"; wipe || log "wipe FAILED"
    log "2P2D random prefill and decode, 16 sessions: $(recall y1_recall 16 both $LB 5)"
    ;;
  *) log "unknown LAYOUT $LAYOUT"; exit 2;;
esac
log "LAYOUT $LAYOUT after random: $(health) $(exc)"
if [ "${STATIC_DOCS:-0}" != 0 ]; then wipe; log "static ${STATIC_DOCS} docs via lb: $(static v3_static $STATIC_DOCS $LB $P0 $D0)"; fi
if [ "${STRESS:-false}" = true ]; then wipe
  timeout 3600 $PY $HARNESS/spill_stress.py --lb $LB --prefill-url $P0 --decode-url $D0 --tokenizer $TOK --prompts $PROMPTS --prefix 131072 --new 8192 --sessions 6 --phases concurrent,abort --flush-targets prefill --phase-timeout 900 --out $OUT/${RUN}_stress.json > $OUT/${RUN}_stress.out 2>&1
  log "C1 stress rc=$? $(tail -3 $OUT/${RUN}_stress.out | tr '\n' ' ' | cut -c1-500); $(health) $(exc)"; fi
sleep 60; evidence | tee -a "$OUT/evidence.txt"
log "LAYOUT $LAYOUT DONE ($RUN): $(health) $(exc)"
