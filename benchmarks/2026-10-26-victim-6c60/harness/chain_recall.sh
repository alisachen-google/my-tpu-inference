#!/usr/bin/env bash
# Victim-recall before/after benchmark of commit 6c60fd77 on 1P1D gpt-oss-120b.
#   after  = 6c60fd77 + tpu-sync 759530c7, victim push + prefix pull + SWA windows on (run static_after_1, reused)
#   before = parent 49ddede7, installed tpu-sync wheel, features off; same budgets (run recall_before_1)
# Per point: flush, fill (N sessions in order), settle until push counters stop, recall oldest first.
set -uo pipefail
D=$HOME/pd_disagg/spill; R=$D/results_recall; L=$D/logs; PY=$HOME/venv/sglang/bin/python; mkdir -p $R
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
log() { echo "$(date -u '+%F %T') $*"; }
POINTS=${POINTS:-"131072:8192:16 131072:8192:24 131072:8192:32 262144:16384:8 262144:16384:12 262144:16384:16"}
CFGS=${CFGS:-"after before"}
SSH="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no sa_101411256518727260534@10.128.15.217"
flush() { for u in http://10.128.15.217:30000 http://10.128.0.90:30000; do
  for i in $(seq 1 30); do c=$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $u/flush_cache); [ "$c" = 200 ] && break; sleep 10; done
  [ "$c" = 200 ] || log "flush $u failed ($c)"; done; }
pushes() { $SSH "sudo -n grep -h '\[victim-push\] role=prefill' /home/alisachen_google_com/pd_disagg/results/runs/$1/prefill/server.log 2>/dev/null | grep TP0 | tail -1" | grep -o 'started=[0-9]*' ; }
for cfg in $CFGS; do
  if [ $cfg = after ]; then run=recall_after_ab_1; launcher=$D/pd_6c60.sh; recipe=$HOME/pd_disagg/recipes/v6c_long/victim/gpt-oss_C_victim.json
  else run=recall_before_1; launcher=$D/pd_base49.sh; recipe=$HOME/pd_disagg/recipes/v6c_long/base/gpt-oss_C_victim.json; fi
  if ! curl -sf -m 5 http://10.128.15.217:8080/health >/dev/null; then
    log "starting $run ($cfg)"; bash $launcher start $recipe $run > $L/${run}_start.log 2>&1
    curl -sf -m 5 http://10.128.15.217:8080/health >/dev/null || { log "$run pair did not come up"; bash $launcher stop all >/dev/null 2>&1; continue; }
  else log "reusing running pair for $run ($cfg)"; fi
  # Address maps of every prefill scheduler, to resolve a native abort's raw stack addresses later.
  $SSH "sudo -n -iu alisachen_google_com bash -lc 'd=/home/alisachen_google_com/pd_disagg/results/runs/$run/prefill/maps; mkdir -p \$d; for p in \$(pgrep -u alisachen_google_com -f sglang::scheduler); do cat /proc/\$p/maps > \$d/\$p.maps; done; ls \$d | wc -l'" | sed 's/^/  saved prefill maps: /'
  for p in $(pgrep -u alisachen_google_com -f 'sglang::schedule''r'); do mkdir -p $HOME/pd_disagg/results/runs/$run/decode/maps; cat /proc/$p/maps > $HOME/pd_disagg/results/runs/$run/decode/maps/$p.maps; done
  for pt in $POINTS; do
    P=$(echo $pt | cut -d: -f1); N=$(echo $pt | cut -d: -f2); S=$(echo $pt | cut -d: -f3)
    label=p$((P/1024))k_n$((N/1024))k_s$S
    curl -sf -m 10 http://10.128.15.217:8080/health >/dev/null || { log "$run LB unhealthy before $label"; break; }
    flush; sleep 10
    log "$run $label stats before"; bash $D/victim_stats.sh $run 2>&1 | sed "s/^/  [$label pre] /"
    A=(--sessions $S --prefix $P --new $N --out-tokens 1024 --concurrency 4 --seed 7 --timeout 1800 --run $run)
    log "$run $label fill"
    timeout 7200 $PY $D/victim_recall.py "${A[@]}" --phase fill --label ${label}_fill --out $R/${run}_${label}_fill.jsonl 2>&1 | grep -E '^SUMMARY|Traceback|Error' | cut -c1-1500
    prev=""; for i in $(seq 1 20); do cur=$(pushes $run); [ -n "$prev" ] && [ "$cur" = "$prev" ] && break; prev=$cur; sleep 15; done
    log "$run $label settled ($cur)"; bash $D/victim_stats.sh $run 2>&1 | sed "s/^/  [$label mid] /"
    log "$run $label recall"
    timeout 7200 $PY $D/victim_recall.py "${A[@]}" --phase recall --label ${label}_recall --out $R/${run}_${label}_recall.jsonl 2>&1 | grep -E '^SUMMARY|Traceback|Error' | cut -c1-1500
    bash $D/victim_stats.sh $run 2>&1 | sed "s/^/  [$label post] /"
  done
  log "$run done"; bash $launcher stop all > /dev/null 2>&1; sleep 30
done
log "ALL DONE"
