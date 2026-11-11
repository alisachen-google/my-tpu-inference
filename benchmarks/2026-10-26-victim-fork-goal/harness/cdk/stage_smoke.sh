#!/usr/bin/env bash
# 1P1D smoke: the stack starts, a short fill/recall round trip completes, pushes and recalls appear in the logs.
source "$HARNESS/common.sh"
fresh_run
P0=$(awk '{print $1}' <<< "$PREFILL_URLS"); D0=$(awk '{print $1}' <<< "$DECODE_URLS")
log "SMOKE start: $(health) $(exc)"
wipe || exit 1
log "SMOKE fill+recall 6 sessions 32k+4k: $(recall s_recall 6 both $LB 5 32768 4096)"
log "SMOKE static 4 docs: $(static s_static 4 $LB $P0 $D0)"
sleep 30; log "SMOKE after: $(health) $(exc)"; evidence | tee -a "$OUT/evidence.txt"
log "SMOKE DONE"
