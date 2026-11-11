#!/usr/bin/env bash
# A1 on 1P1D: recall ladder (sessions) and static ladder (documents), 128k+8k requests, caches wiped before every
# point. SWITCH on/off is the server-side arm. RECALL_POINTS / STATIC_POINTS override the ladders.
source "$HARNESS/common.sh"
fresh_run
P0=$(awk '{print $1}' <<< "$PREFILL_URLS"); D0=$(awk '{print $1}' <<< "$DECODE_URLS")
RECALL_POINTS=${RECALL_POINTS:-"8 12 16 20 24"}; STATIC_POINTS=${STATIC_POINTS:-"4 8 12 16 20 24 28"}
log "A1 start ($RUN): $(health) $(exc)"
for n in $RECALL_POINTS; do
  wipe || { log "A1 wipe FAILED before recall $n"; exit 1; }
  log "A1 recall $n sessions: $(recall recall_$n $n both $LB 5)"
  log "A1 after recall $n: $(health) $(exc)"
done
for k in $STATIC_POINTS; do
  wipe || { log "A1 wipe FAILED before static $k"; exit 1; }
  log "A1 static $k docs: $(static static_$k $k $LB $P0 $D0)"
  log "A1 after static $k: $(health) $(exc)"
done
sleep 60; evidence | tee -a "$OUT/evidence.txt"
log "A1 DONE ($RUN): $(health) $(exc)"
