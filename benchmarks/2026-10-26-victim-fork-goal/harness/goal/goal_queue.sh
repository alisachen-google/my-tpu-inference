#!/usr/bin/env bash
# Goal queue on prefill a + decode v7, started once host a is free.
#  Stage 1: Qwen3 (full attention), PR 1992 tree, write-back: switch off then on, recall + static ladders, edge cases.
#  Stage 2: PR 1992 must refuse a hybrid model at start; then gpt-oss (hybrid), PR 1991 tree, write-back: off then on.
set -u
L=$HOME/pd_disagg/live; SP=$HOME/pd_disagg/spill; A=10.128.15.217; V=10.128.15.239
QWEN=/mnt/data/tt/hf-cache/hub/models--Qwen--Qwen3-30B-A3B-Instruct-2507-FP8/snapshots/5a5a776300a41aaa681dd7ff0106608ef2bc90db
GPT=/mnt/data/tt/hf-cache/hub/models--openai--gpt-oss-120b/snapshots/b5c939de8f754692c1647ca79fbf85e8c1e70f8a
SSHA="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20 sa_101411256518727260534@$A"
log() { echo "$(date -u '+%F %T') $*" >> $L/goal_queue.log; }
PM() { PREFILL_IP=$A DECODE_IP=$V bash $HOME/pd_disagg/scripts/pd_main.sh "$@"; }
stop_pair() { PM stop > /dev/null 2>&1; sleep 25; }
wait_free() { while true; do
    h=$($SSHA "sudo fuser -v /dev/vfio/0 2>&1 | awk 'NR>1{print \$(NF-3)}' | sort -u | grep -v alisachen | tr '\n' ' '" 2>/dev/null); rc=$?
    [ $rc -eq 0 ] && [ -z "$(echo $h | tr -d ' ')" ] && return 0; sleep 120; done; }
deploy() { ( cd $L; bash deploy_1992.sh $A $1 > deploy_a.log 2>&1 & bash deploy_1992.sh $V $1 > deploy_v7.log 2>&1; wait
    grep -q DEPLOY_OK deploy_a.log && grep -q DEPLOY_OK deploy_v7.log ); }
hang_dump() { # run: py-spy stacks of every scheduler rank on both hosts
  for ip in $A $V; do ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no sa_101411256518727260534@$ip 'for p in $(pgrep -u alisachen_google_com -f "scheduler_T[P]"); do echo "=== $p $(tr -d "\0" < /proc/$p/cmdline | cut -c1-60)"; sudo /home/alisachen_google_com/venv/sglang-main/bin/py-spy dump --pid $p 2>&1 | head -60; done' > $SP/results_goal/hang_${1}_$ip.txt 2>&1; done; }
sweep() { # name recipe tokenizer recall-list static-list [keep]
  local name=$1 recipe=$2; log "sweep $name start ($recipe)"
  ( cd $SP; export TOK=$3 RECALL="$4" STATIC="$5" A_IP=$A B_IP=$V LAUNCHER=$HOME/pd_disagg/scripts/pd_main.sh CFG=after FLUSH_TRIES=15 KINDS="recall static" NAME=$name RUN=${name}_1 RECIPE=$L/$recipe
    timeout --signal=TERM 14400 bash chain_pair.sh > logs/goal_${name}_1.log 2>&1; echo "CHAIN_EXIT $?" >> logs/goal_${name}_1.log )
  local rc=$(grep CHAIN_EXIT $SP/logs/goal_${name}_1.log | tail -1 | awk '{print $2}')
  log "sweep $name end: exit=$rc points=$(grep -c '^POINT' $SP/logs/goal_${name}_1.log) errors=$(grep '^POINT' $SP/logs/goal_${name}_1.log | grep -vc '"errors": 0')"
  [ "$rc" = 124 ] && { log "sweep $name HUNG (4 h timeout): dumping stacks"; hang_dump $name; }
  bash $L/evidence.sh ${name}_1 > $SP/results_goal/evidence_${name}.txt 2>&1
}
QR="131072:8192:8 131072:8192:12 131072:8192:16 131072:8192:20 131072:8192:24"
QS="131072:8192:4 131072:8192:8 131072:8192:12 131072:8192:16 131072:8192:20 131072:8192:24 131072:8192:28"
GR="131072:8192:8 131072:8192:12 131072:8192:16"
GS="131072:8192:4 131072:8192:8 131072:8192:12 131072:8192:16"

log "waiting for host a"; wait_free; log "host a is free"
for stage in ${STAGES:-1 2}; do
if [ $stage = 1 ]; then
  deploy $HOME/sglang-1992 || { log "deploy of PR 1992 failed"; exit 1; }
  log "stage 1: PR 1992 $(cat $HOME/sglang-1992/.git 2>/dev/null | head -1) deployed"
  sweep g1992_off pd_1992_qwen_wb_off.json $QWEN "$QR" "$QS"; stop_pair
  sweep g1992_on pd_1992_qwen_wb.json $QWEN "$QR" "$QS"
  log "edges on g1992_on_1"; timeout 14400 bash $L/edges.sh g1992_on_1 $L/pd_1992_qwen_wb.json $QWEN >> $L/goal_queue.log 2>&1; log "edges exit $?"
  bash $L/evidence.sh g1992_on_1 > $SP/results_goal/evidence_g1992_on_after_edges.txt 2>&1
  stop_pair
else
  # PR 1992 moves full attention only: a hybrid model must be refused at start, by name, not hang.
  log "refusal check: gpt-oss on the PR 1992 tree with the switch on"
  timeout 900 env PREFILL_IP=$A DECODE_IP=$V bash $HOME/pd_disagg/scripts/pd_main.sh start $L/pd_1991_gptoss_wb_on.json g1992_refuse_1 > $SP/logs/g1992_refuse_1_start.log 2>&1
  log "refusal check: prefill log says: $($SSHA "sudo grep -h 'is not supported on this\|UnsupportedSpillConfig' /home/alisachen_google_com/pd_disagg/results/runs/g1992_refuse_1/prefill/server.log | head -1 | cut -c1-400")"
  stop_pair
  deploy $HOME/sglang-mvp || { log "deploy of PR 1991 failed"; exit 1; }
  log "stage 2: PR 1991 deployed"
  sweep g1991_off pd_1991_gptoss_wb_off.json $GPT "$GR" "$GS"; stop_pair
  sweep g1991_on pd_1991_gptoss_wb_on.json $GPT "$GR" "$GS"
  log "edges on g1991_on_1"; timeout 14400 bash $L/edges.sh g1991_on_1 $L/pd_1991_gptoss_wb_on.json $GPT >> $L/goal_queue.log 2>&1; log "edges exit $?"
  bash $L/evidence.sh g1991_on_1 > $SP/results_goal/evidence_g1991_on_after_edges.txt 2>&1
  stop_pair
fi
done
log "GOAL QUEUE DONE"
