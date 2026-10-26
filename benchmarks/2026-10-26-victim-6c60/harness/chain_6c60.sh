#!/usr/bin/env bash
# Commit 6c60fd77 victim-cache benchmark (methodology: unique 4k prefix, 4 turns x 2 rounds, 64/128,
# KV_CHAIN, seed 1). Victim config then baseline, identical points. Progress: logs/chain_6c60.log.
set -uo pipefail
D=$HOME/pd_disagg/spill; R=$D/results; L=$D/logs; PY=$HOME/venv/sglang/bin/python
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
log() { echo "$(date -u '+%F %T') $*"; }
SWEEP=${SWEEP:-"16 32 64 96 128 192 256 384 512 768 1024 1536"}
CONC_SWEEP=${CONC_SWEEP:-"128:1 128:2 128:4 128:8 1024:4"}
REPEAT=${REPEAT:-"512 1024"}
flush_both() { for u in http://10.128.15.217:30000 http://10.128.0.90:30000; do curl -s -m 300 -X POST "$u/flush_cache" >/dev/null; done; }
point() { # run n conc label
  flush_both; sleep 5
  log "$1 sessions=$2 conc=$3 label=$4"
  timeout 14400 $PY $D/victim_sessions.py --sessions $2 --concurrency $3 --run $1 --label "$4" --out $R/${1}_sweep.jsonl 2>&1 | grep -E '^PASS|^SUMMARY|Traceback|Error' | cut -c1-900
  bash $D/victim_stats.sh $1
}
phases() { # run
  curl -sf -m 5 http://10.128.15.217:8080/health >/dev/null || { log "LB not healthy"; return 1; }
  for n in $SWEEP; do point $1 $n 8 "sweep_n${n}_c8"; done
  for nc in $CONC_SWEEP; do point $1 ${nc%%:*} ${nc##*:} "conc_n${nc%%:*}_c${nc##*:}"; done
  for n in $REPEAT; do point $1 $n 8 "repeat_n${n}_c8"; done
}
for cfg in victim base; do
  run=v6c_${cfg}_1
  log "starting pair $run"
  bash $D/pd_6c60.sh start $HOME/pd_disagg/recipes/v6c/$cfg/gpt-oss_C_v6c.json $run > $L/${run}_start.log 2>&1
  phases $run > $L/${run}_phase.log 2>&1 || log "phases failed for $run"
  log "$run done: $(grep -c SUMMARY $L/${run}_phase.log) summaries"
  bash $D/pd_6c60.sh stop all >> $L/${run}_phase.log 2>&1; sleep 30
done
log "ALL DONE"
