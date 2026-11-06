#!/usr/bin/env bash
# Run the two static write-back arms as soon as a 1P/1D pair is free: decode on b, prefill on a (preferred) or v7.
# A host is free when no process holds its TPU. Never touches other users' processes.
cd ~/pd_disagg/spill; echo $$ > logs/static_wb_when_free.pid; LOG=logs/static_wb_when_free.log
A=10.128.15.217; V7=10.128.15.239; B=10.128.0.90
SSH="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20"
log() { echo "$(date -u '+%F %T') $*" >> $LOG; }
holder() { # ip -> names of TPU holders ("" when free, "?" when the host cannot be asked)
  if [ "$1" = "$B" ]; then out=$(sudo -n fuser -v /dev/vfio/0 2>&1) || true
  else out=$($SSH sa_101411256518727260534@$1 "sudo -n fuser -v /dev/vfio/0 2>&1; echo RC_OK") ; echo "$out" | grep -q RC_OK || { echo "?"; return; }; fi
  echo "$out" | awk '/vfio/{print $2}' | sort -u | tr '\n' ' '; }
for arm in off spill; do
  tries=0
  until grep -q "GOAL after DONE" logs/goal_swb_${arm}_1.log 2>/dev/null; do
    hb=$(holder $B); ha=$(holder $A); hv=$(holder $V7)
    if [ -z "$hb" ] && [ -z "$ha" ]; then pre=$A; elif [ -z "$hb" ] && [ -z "$hv" ]; then pre=$V7; else pre=""; fi
    if [ -z "$pre" ]; then log "waiting ($arm): b=[$hb] a=[$ha] v7=[$hv]"; sleep 300; continue; fi
    tries=$((tries+1)); [ $tries -gt 4 ] && { log "giving up on $arm after 4 starts"; exit 1; }
    [ -f logs/goal_swb_${arm}_1.log ] && mv logs/goal_swb_${arm}_1.log logs/goal_swb_${arm}_1.attempt$tries.log
    log "starting arm $arm: prefill $pre, decode $B (start #$tries)"
    A_IP=$pre B_IP=$B ARMS=$arm bash static_wb_queue.sh
    log "arm $arm returned: $(grep -c POINT logs/goal_swb_${arm}_1.log 2>/dev/null) points, done=$(grep -c 'GOAL after DONE' logs/goal_swb_${arm}_1.log 2>/dev/null)"
  done
done
log "BOTH ARMS DONE"
