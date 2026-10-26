#!/usr/bin/env bash
# Static prefix-reuse before/after benchmark of commit 6c60fd77 on a+b (1P1D gpt-oss-120b).
#   CFGS="before|after" POINTS="<prefix>:<new>:<K> ..." chain_static_reuse.sh
set -uo pipefail
D=$HOME/pd_disagg/spill; R=$D/results_static_reuse; L=$D/logs; PY=$HOME/venv/sglang/bin/python; mkdir -p $R
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
log() { echo "$(date -u '+%F %T') $*"; }
POINTS=${POINTS:-"131072:8192:4 131072:8192:8 131072:8192:12 131072:8192:16 131072:8192:20 131072:8192:24 131072:8192:28 262144:16384:2 262144:16384:4 262144:16384:6 262144:16384:8 262144:16384:10 262144:16384:12 262144:16384:14"}
CFGS=${CFGS:?before or after}
flush() { for u in http://10.128.15.217:30000 http://10.128.0.90:30000; do
  for i in $(seq 1 30); do c=$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $u/flush_cache); [ "$c" = 200 ] && break; sleep 10; done
  [ "$c" = 200 ] || log "flush $u failed ($c)"; done; }
for cfg in $CFGS; do
  if [ $cfg = after ]; then run=recall_after_ab_1; launcher=$D/pd_6c60.sh; recipe=$HOME/pd_disagg/recipes/v6c_long/victim/gpt-oss_C_victim.json
  else run=recall_before_1; launcher=$D/pd_base49.sh; recipe=$HOME/pd_disagg/recipes/v6c_long/base/gpt-oss_C_victim.json; fi
  if ! curl -sf -m 5 http://10.128.15.217:8080/health >/dev/null; then
    log "starting $run ($cfg)"; bash $launcher start $recipe $run > $L/${run}_static_start.log 2>&1
    curl -sf -m 5 http://10.128.15.217:8080/health >/dev/null || { log "$run pair did not come up"; bash $launcher stop all >/dev/null 2>&1; continue; }
  else log "reusing running pair for $run ($cfg)"; fi
  for pt in $POINTS; do
    P=$(echo $pt | cut -d: -f1); N=$(echo $pt | cut -d: -f2); K=$(echo $pt | cut -d: -f3)
    label=static_p$((P/1024))k_n$((N/1024))k_k$K
    curl -sf -m 10 http://10.128.15.217:8080/health >/dev/null || { log "$run LB unhealthy before $label"; break; }
    flush; sleep 10
    log "$run $label"
    timeout 7200 $PY $D/static_reuse.py --prefixes $K --visits 3 --prefix $P --new $N --out-tokens 1024 --concurrency 4 \
      --seed 13 --run $run --label $label --out $R/${run}_$label.jsonl 2>&1 | grep -E '^SUMMARY|Traceback|Error' | cut -c1-1500
    bash $D/victim_stats.sh $run 2>&1 | sed "s/^/  [$label post] /"
  done
  log "$run static done"; bash $launcher stop all > /dev/null 2>&1; sleep 30
done
log "ALL DONE"
