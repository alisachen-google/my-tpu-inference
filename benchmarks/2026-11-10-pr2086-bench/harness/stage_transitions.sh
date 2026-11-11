#!/usr/bin/env bash
# PR 2086 2P2D campaign: sticky (prefill, decode) pair transitions, write-back on both roles, SWITCH on/off arm.
# Every session is pinned to one pair per phase through that pair's mini-lb (lb_pin P D). Each transition is its
# own point and starts from wiped caches: fill 12 sessions on (p0,d0); 24 short sessions through prefill 0 so
# write-back evicts the filled branches from its host tier and the pushes to decode 0 happen; then the return on
# the target pair. The return's POINT carries the prefill-side hit, throughput, latency and the per-engine request
# deltas (route_ok = only the target pair served it).
#   T1 return on (p0,d0)   same pair
#   T2 return on (p1,d0)   other prefill, same decode: the recall must come from d0 into p1
#   T3 return on (p0,d1)   same prefill, other decode: p0 holds or recalls the branch
#   T4 return on (p1,d1)   both switched
#   chain: one fill, then the same sessions return on (p0,d0), (p1,d0), (p0,d1), (p1,d1) in turn
#   random: 16 sessions fill and return through the random mini-lb (uncontrolled case)
source "$HARNESS/common.sh"
fresh_run
log "TRANSITIONS start ($RUN, policy ${WRITE_POLICY:-?}, switch ${SWITCH:-?}): $(health) $(exc)"
log "pins: $(for p in 0 1; do for d in 0 1; do printf 'p%sd%s=%s ' $p $d $(hc $(lb_pin $p $d)/health); done; done)"
transition() { local name=$1 p=$2 d=$3 seed=$4
  wipe || { log "$name wipe FAILED"; return 1; }
  log "$name fill (p0,d0) 12 sessions: $(recall ${name}_fill 12 fill $(lb_pin 0 0) $seed 131072 8192 4 p0d0)"
  log "$name pushes: 24 short sessions via prefill 0: $(keepalive $(lb_pin 0 0) ${name}_ka)"
  sleep ${SETTLE:-20}
  log "$name return (p$p,d$d): $(recall ${name}_ret 12 recall $(lb_pin $p $d) $seed 131072 8192 4 p${p}d${d})"
  log "$name after: $(health) $(exc)"; }
transition T1_p0d0 0 0 51
transition T2_p1d0 1 0 52
transition T3_p0d1 0 1 53
transition T4_p1d1 1 1 54
# four-leg chain
wipe || log "chain wipe FAILED"
log "chain fill (p0,d0) 12 sessions: $(recall chain_fill 12 fill $(lb_pin 0 0) 55 131072 8192 4 p0d0)"
log "chain pushes: 24 short sessions via prefill 0: $(keepalive $(lb_pin 0 0) chain_ka)"
sleep ${SETTLE:-20}
leg=1; for pd in "0 0" "1 0" "0 1" "1 1"; do set -- $pd
  log "chain leg $leg return (p$1,d$2): $(recall chain_l${leg}_p$1d$2 12 recall $(lb_pin $1 $2) 55 131072 8192 4 p$1d$2)"
  log "chain leg $leg after: $(health) $(exc)"; leg=$((leg+1)); done
# random routing
wipe || log "random wipe FAILED"
log "random fill 16 sessions via random lb: $(recall random_fill 16 fill $LB 5 131072 8192 4 any)"
sleep ${SETTLE:-20}
log "random return 16 sessions via random lb: $(recall random_ret 16 recall $LB 5 131072 8192 4 any)"
log "random after: $(health) $(exc)"
sleep 60; evidence | tee -a "$OUT/evidence.txt"
log "TRANSITIONS DONE ($RUN): $(health) $(exc)"
