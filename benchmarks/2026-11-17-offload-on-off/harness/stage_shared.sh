#!/usr/bin/env bash
# The PR 2052 test case (issue 2051) on a 1P1D pair: sessions that share one hot prefix (8k tokens, a system prompt)
# before their own tokens (131,072 prefix in total + 8,192 new), filled, settled 60 s, then returned oldest first;
# 64 output tokens, seed 71, caches wiped before every case (goal_shared_fix.sh / goal_shared_fix2.sh):
#   shared16 16 sessions one at a time; shared16b 16 at 2 concurrent; shared20 20 at 4; shared24 24 at 4;
#   indep16  16 independent sessions one at a time (no shared prefix, the regression check).
# Each phase is its own POINT; then the offload counters per point from both server logs.
source "$HARNESS/common.sh"
fresh_run
export OUT_TOKENS=64 SETTLE=60
log "SHARED start ($RUN, policy ${WRITE_POLICY:-?}, switch ${SWITCH:-?}): $(health) $(exc)"
case_() { # label sessions concurrency shared-prefix
  wipe || { log "SHARED wipe FAILED before $1"; exit 1; }
  export SHARED_PREFIX=$4
  log "$1 fill ($2 sessions, concurrency $3, shared $4): $(recall ${1}_fill $2 fill $LB 71 131072 8192 $3 p0d0)"
  sleep $SETTLE
  log "$1 return: $(recall ${1}_ret $2 recall $LB 71 131072 8192 $3 p0d0)"
  log "after $1: $(health) $(exc)"; }
for c in ${SHARED_CASES:-shared16:16:1:8192 shared16b:16:2:8192 shared20:20:4:8192 shared24:24:4:8192 indep16:16:1:0}; do
  IFS=: read -r l n k sp <<< "$c"; case_ $l $n $k $sp
done
sleep 60; evidence | tee -a "$OUT/evidence.txt"
log "SHARED DONE ($RUN): $(health) $(exc)"
