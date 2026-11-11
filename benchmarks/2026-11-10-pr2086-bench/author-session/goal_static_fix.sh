#!/usr/bin/env bash
# Static-reuse gap experiment for PR 2086 (gpt-oss-120b, write-back, switch ON on both arms), prefill .246 + decode v7:
#   arm A: ~/sglang-mvp  (PR head 54a80863a6: the prefill keeps only the last SWA window of each path)
#   arm B: ~/sglang-exp  (same head, the prefill's SWA window retention left to upstream: every evicted node's window)
# Each arm: static 8/12/16 docs, then recall 12 sessions (pushes must still carry windows), evidence, both server logs kept.
set -u
L=$HOME/pd_disagg/live; SP=$HOME/pd_disagg/spill; R=$SP/results_goal; A=10.128.0.246; V=10.128.15.239
PY=$HOME/venv/sglang/bin/python
GPT=/mnt/data/tt/hf-cache/hub/models--openai--gpt-oss-120b/snapshots/b5c939de8f754692c1647ca79fbf85e8c1e70f8a
SSHO="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20"
SSHA="$SSHO sa_101411256518727260534@$A"; SSHV="$SSHO sa_101411256518727260534@$V"
RUNS=/home/alisachen_google_com/pd_disagg/results/runs
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
log() { echo "$(date -u '+%F %T') $*" >> $L/goal_followup.log; }
PM() { PREFILL_IP=$A DECODE_IP=$V bash $HOME/pd_disagg/scripts/pd_main.sh "$@"; }
released() { $SSHO sa_101411256518727260534@$1 "h=\$(sudo fuser /dev/vfio/* 2>/dev/null | wc -w); p=\$(sudo ss -ltnp 2>/dev/null | grep -c 'alisachen\|:30000 \|:31000 \|:8080 \|:8998 '); [ \"\$h\" = 0 ] && [ \"\$p\" = 0 ]" 2>/dev/null; }
stop_pair() { PM stop > /dev/null 2>&1; for i in $(seq 1 18); do released $A && released $V && break; sleep 10; done; sleep 15; }
deploy() { ( cd $L; bash deploy_1992.sh $A $1 > deploy_a.log 2>&1 & bash deploy_1992.sh $V $1 > deploy_v7.log 2>&1; wait
    grep -q DEPLOY_OK deploy_a.log && grep -q DEPLOY_OK deploy_v7.log ); }
health() { echo "prefill=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:30000/health) decode=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$V:30000/health) lb=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:8080/health)"; }
exc() { echo "prefill_sched_exc=$($SSHA "sudo grep -c 'Scheduler hit an exception\|out of memory' $RUNS/$1/prefill/server.log" 2>/dev/null) decode_sched_exc=$($SSHV "sudo grep -c 'Scheduler hit an exception\|out of memory' $RUNS/$1/decode/server.log" 2>/dev/null)"; }
evidence() { PIP=$A DIP=$V bash $L/evidence.sh $1 > $R/evidence_$1.txt 2>&1; log "$1 evidence: $(grep -h 'victim-push\|totals=' $R/evidence_$1.txt | sed 's/.*\(role=\|totals=\)/\1/' | cut -c1-260 | tr '\n' ' ')"; }
keep_logs() { mkdir -p $SP/prefill_logs $SP/decode_logs
  rsync -a -e "$SSHO" --rsync-path='sudo rsync' sa_101411256518727260534@$A:$RUNS/$1/prefill/server.log $SP/prefill_logs/$1_a.log 2>/dev/null
  rsync -a -e "$SSHO" --rsync-path='sudo rsync' sa_101411256518727260534@$V:$RUNS/$1/decode/server.log $SP/decode_logs/$1_v.log 2>/dev/null; }
sweep() { # name recipe
  local name=$1; log "sweep $name start ($2)"
  ( cd $SP; export TOK=$GPT RECALL="131072:8192:12" STATIC="131072:8192:8 131072:8192:12 131072:8192:16" A_IP=$A B_IP=$V LAUNCHER=$HOME/pd_disagg/scripts/pd_main.sh CFG=after FLUSH_TRIES=15 KINDS="static recall" NAME=$name RUN=${name}_1 RECIPE=$L/$2
    timeout --signal=TERM 10800 bash chain_pair.sh > logs/goal_${name}_1.log 2>&1; echo "CHAIN_EXIT $?" >> logs/goal_${name}_1.log )
  log "sweep $name end: exit=$(grep CHAIN_EXIT $SP/logs/goal_${name}_1.log | tail -1 | awk '{print $2}') points=$(grep -c '^POINT' $SP/logs/goal_${name}_1.log) strict: $($PY $L/strict.py $R/${name}_1_*.jsonl) $(exc ${name}_1)"
  grep '^POINT' $SP/logs/goal_${name}_1.log | while read -r l; do log "$name $(echo "$l" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()[6:]); print(d['label'], 'prefill_hit', d.get('prefill_hit'), 'ttft50', d.get('ttft50'), 'tok_s', d.get('total_tok_s'))")"; done; }

for spec in "sglang-mvp g2086a_on" "sglang-exp g2086b_on"; do
  set -- $spec; tree=$1; name=$2
  stop_pair
  deploy $HOME/$tree || { log "STATICFIX deploy of $tree failed"; continue; }
  $SSHA "sudo rm -rf $RUNS/${name}_1" 2>/dev/null; $SSHV "sudo rm -rf $RUNS/${name}_1" 2>/dev/null
  rm -f $R/${name}_1_*.jsonl
  log "STATICFIX $tree $(git -C $HOME/$tree rev-parse --short HEAD)$(git -C $HOME/$tree diff --quiet || echo '+exp') on .246 + v7 ($name): static 8/12/16 then recall 12, switch on"
  sweep $name pd_1991_gptoss_wb_on.json
  evidence ${name}_1
  keep_logs ${name}_1
  stop_pair
done
log "GOAL STATICFIX DONE"
