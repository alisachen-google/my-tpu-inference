#!/usr/bin/env bash
# The static prefix-reuse ladders of the PR 1789 description on a 1P1D pair: K documents x 3 visits, shuffled,
# concurrency 4, 256 output tokens, seed 13, caches wiped before every point.
#   128k+8k   K = 4 8 12 16 20 24 28      (labels static_<K>)
#   256k+16k  K = 2 4 6 8 10 12 14        (labels static256_<K>)
source "$HARNESS/common.sh"
fresh_run
P0=$(awk '{print $1}' <<< "$PREFILL_URLS"); D0=$(awk '{print $1}' <<< "$DECODE_URLS")
log "STATIC1789 start ($RUN, policy ${WRITE_POLICY:-?}, switch ${SWITCH:-?}): $(health) $(exc)"
ladder() { # label-prefix prefix new points
  export STATIC_PREFIX=$2 STATIC_NEW=$3; local k
  for k in $4; do
    wipe || { log "STATIC1789 wipe FAILED before $1_$k"; exit 1; }
    log "$1 $k docs ($2+$3): $(static ${1}_$k $k $LB $P0 $D0 p0d0)"
    log "after $1 $k: $(health) $(exc)"
  done; }
# RECALL_POINTS (e.g. "8 12 16") runs the recall ladder of stage_bench.sh first: fill, settle, return, 128k+8k.
for n in ${RECALL_POINTS:-}; do
  wipe || { log "STATIC1789 wipe FAILED before recall $n"; exit 1; }
  log "recall $n fill: $(recall recall_${n}_fill $n fill $LB 5 131072 8192 4 p0d0)"
  sleep ${SETTLE:-20}
  log "recall $n return: $(recall recall_${n}_ret $n recall $LB 5 131072 8192 4 p0d0)"
  log "after recall $n: $(health) $(exc)"
done
ladder static 131072 8192 "${STATIC_POINTS_128:-4 8 12 16 20 24 28}"
ladder static256 262144 16384 "${STATIC_POINTS_256:-2 4 6 8 10 12 14}"
sleep 60; evidence | tee -a "$OUT/evidence.txt"
log "STATIC1789 DONE ($RUN): $(health) $(exc)"
