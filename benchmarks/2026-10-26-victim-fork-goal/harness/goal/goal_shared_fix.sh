#!/usr/bin/env bash
# Live validation of the shared-prefix fix (issue 2051) on g (prefill) + v7 (decode) with the fix branch worktree:
# the shared-prefix stage (16 sessions one at a time, then 20 and 24 at 4 concurrent) plus one independent-session recall
# point as a regression check. Expect pushes and recalls > 0, hits beyond the shared 8k, no exception, no refused drop.
set -u
L=$HOME/pd_disagg/live; SP=$HOME/pd_disagg/spill; R=$SP/results_goal; A=10.128.0.175; V=10.128.15.239
PY=$HOME/venv/sglang/bin/python
QWEN=/mnt/data/tt/hf-cache/hub/models--Qwen--Qwen3-30B-A3B-Instruct-2507-FP8/snapshots/5a5a776300a41aaa681dd7ff0106608ef2bc90db
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
checks() { $SSHA "P=$RUNS/$1/prefill/server.log; echo sched_exc=\$(sudo grep -c 'Scheduler hit an exception' \$P) oom=\$(sudo grep -c 'out of memory' \$P) drop_declined=\$(sudo grep -c 'subtree drop declined' \$P) pulls=\$(sudo grep -c 'TP0 EP0. .prefix-pull' \$P) push_stats=\\\"\$(sudo grep -h 'TP0 EP0. .victim-push. role=prefill' \$P | tail -1 | sed 's/.*role=prefill //' | cut -c1-160)\\\"" 2>/dev/null; }
flush_one() { for i in $(seq 1 ${2:-30}); do c=$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $1/flush_cache); [ "$c" = 200 ] && return 0; sleep 10; done; return 1; }
wipe() { flush_one http://$V:30000 && flush_one http://$A:30000; }
start() { timeout 6000 env PREFILL_IP=$A DECODE_IP=$V bash $HOME/pd_disagg/scripts/pd_main.sh start $1 $2 > $SP/logs/${2}_start.log 2>&1; log "$2 started: $(health)"; }
hit() { $PY $SP/prefill_hit_window.py $R/$1.jsonl $SP/prefill_logs/$2.log 2>/dev/null | tail -1; }
shared() { # run label sessions concurrency shared-prefix
  wipe || log "$1 wipe before $2 FAILED"
  $PY $SP/victim_recall.py --sessions $3 --prefix 131072 --new 8192 --shared-prefix $5 --out-tokens 64 --concurrency $4 --seed 71 --run $1 --phase both --settle 60 --label $2 --tokenizer $QWEN \
    --lb http://$A:8080 --out $R/${1}_$2.jsonl > $R/${1}_$2.out 2>&1
  rsync -a -e "$SSHO" --rsync-path='sudo rsync' sa_101411256518727260534@$A:$RUNS/$1/prefill/server.log $SP/prefill_logs/$1_a.log 2>/dev/null
  log "SHAREDFIX $1 $2 ($3 sessions, concurrency $4, shared $5): $($PY $L/strict.py $R/${1}_$2.jsonl); $(health) $(checks $1); recall-phase $(hit ${1}_$2 ${1}_a)"; }
evidence() { PIP=$A DIP=$V bash $L/evidence.sh $1 > $R/evidence_$1.txt 2>&1; log "$1 evidence: $(grep -h 'victim-push\|totals=' $R/evidence_$1.txt | sed 's/.*\(role=\|totals=\)/\1/' | cut -c1-260 | tr '\n' ' ')"; }

RUN=g1992x_shared_1
stop_pair
deploy $HOME/sglang-shared || { log "SHAREDFIX deploy of the fix tree failed"; exit 1; }
$SSHA "sudo rm -rf $RUNS/$RUN" 2>/dev/null; $SSHV "sudo rm -rf $RUNS/$RUN" 2>/dev/null
rm -f $R/${RUN}_*.jsonl
log "SHAREDFIX fix tree $(git -C $HOME/sglang-shared rev-parse --short HEAD) on g + v7 ($RUN): shared 8k prefix 16 one-at-a-time, 20 and 24 at 4 concurrent, then 16 independent sessions"
start $L/pd_1992_qwen_wb.json $RUN
shared $RUN shared16 16 1 8192
shared $RUN shared20c 20 4 8192
shared $RUN shared24c 24 4 8192
shared $RUN indep16 16 1 0
evidence $RUN
stop_pair
log "GOAL SHAREDFIX DONE"
