#!/usr/bin/env bash
# After goal_followup2.sh: F5 a decode whose DRAM is smaller than one session must decline pushes, not hang or fail requests.
set -u
L=$HOME/pd_disagg/live; SP=$HOME/pd_disagg/spill; R=$SP/results_goal; A=10.128.15.217; V=10.128.15.239
PY=$HOME/venv/sglang/bin/python
QWEN=/mnt/data/tt/hf-cache/hub/models--Qwen--Qwen3-30B-A3B-Instruct-2507-FP8/snapshots/5a5a776300a41aaa681dd7ff0106608ef2bc90db
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
log() { echo "$(date -u '+%F %T') $*" >> $L/goal_followup.log; }
PM() { PREFILL_IP=$A DECODE_IP=$V bash $HOME/pd_disagg/scripts/pd_main.sh "$@"; }
health() { echo "prefill=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:30000/health) decode=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$V:30000/health) lb=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:8080/health)"; }
flush_one() { for i in $(seq 1 ${2:-30}); do c=$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $1/flush_cache); [ "$c" = 200 ] && return 0; sleep 10; done; return 1; }
until grep -q "GOAL FOLLOWUP DONE" $L/goal_followup.log; do sleep 60; done
RUN=g1992b_smalldecode_1
# The tree on the hosts is whatever the last step deployed: F5 needs PR 1992.
( cd $L; bash deploy_1992.sh $A $HOME/sglang-1992 > deploy_a.log 2>&1 & bash deploy_1992.sh $V $HOME/sglang-1992 > deploy_v7.log 2>&1; wait )
grep -q DEPLOY_OK $L/deploy_a.log && grep -q DEPLOY_OK $L/deploy_v7.log || { log "F5 deploy failed"; exit 1; }
timeout 6000 env PREFILL_IP=$A DECODE_IP=$V bash $HOME/pd_disagg/scripts/pd_main.sh start $L/pd_1992_qwen_wb_smalldecode.json $RUN > $SP/logs/${RUN}_start.log 2>&1
log "F5 $RUN started (decode hicache_ratio 0.15, less than one session): $(health)"
$PY $SP/victim_recall.py --sessions 16 --prefix 131072 --new 8192 --out-tokens 16 --concurrency 4 --seed 5 --run $RUN --phase both --settle 20 --label declined --tokenizer $QWEN --lb http://$A:8080 --out $R/${RUN}_declined.jsonl > $R/${RUN}_declined.out 2>&1
t0=$(date +%s); flush_one http://$A:30000 30; fp=$?; t1=$(date +%s); flush_one http://$V:30000 30; fv=$?
log "F5 requests: $($PY $L/strict.py $R/${RUN}_declined.jsonl); flush after the load stopped: prefill rc=$fp after $((t1-t0)) s, decode rc=$fv after $(( $(date +%s)-t1 )) s; $(health)"
bash $L/evidence.sh $RUN > $R/evidence_$RUN.txt 2>&1
log "F5 evidence: $(grep -h 'victim-push' $R/evidence_$RUN.txt | sed 's/.*role=/role=/' | cut -c1-200 | tr '\n' ' ') $(grep -h 'warnings:\|errors:' $R/evidence_$RUN.txt | tr '\n' ' ')"
PM stop > /dev/null 2>&1
log "GOAL FOLLOWUP3 DONE"
