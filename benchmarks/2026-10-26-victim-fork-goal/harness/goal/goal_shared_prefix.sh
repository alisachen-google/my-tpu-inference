#!/usr/bin/env bash
# Exercise the adopt_received_backups fix live: sessions that share a hot 8k-token prefix. The shared chunk stays on the
# device (unbacked under write-back) while each session's own tail is pushed and recalled as a host-only branch below it,
# the shape that used to be undroppable. Expect adopted_backup_tokens > 0, no "subtree drop declined", no out-of-memory.
# Both trees on g (prefill) + v7 (decode).
set -u
L=$HOME/pd_disagg/live; SP=$HOME/pd_disagg/spill; R=$SP/results_goal; A=10.128.0.175; V=10.128.15.239
PY=$HOME/venv/sglang/bin/python
QWEN=/mnt/data/tt/hf-cache/hub/models--Qwen--Qwen3-30B-A3B-Instruct-2507-FP8/snapshots/5a5a776300a41aaa681dd7ff0106608ef2bc90db
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
checks() { $SSHA "P=$RUNS/$1/prefill/server.log; echo sched_exc=\$(sudo grep -c 'Scheduler hit an exception' \$P) oom=\$(sudo grep -c 'out of memory' \$P) drop_declined=\$(sudo grep -c 'subtree drop declined' \$P) dropped_no_backup=\$(sudo grep -c 'dropped without backup' \$P) \$(sudo grep -h 'TP0 EP0. .prefix-pull' \$P | tail -1 | grep -o \"'adopted_backup_tokens': [0-9]*\")" 2>/dev/null; }
flush_one() { for i in $(seq 1 ${2:-30}); do c=$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $1/flush_cache); [ "$c" = 200 ] && return 0; sleep 10; done; return 1; }
wipe() { flush_one http://$V:30000 && flush_one http://$A:30000; }
start() { timeout 6000 env PREFILL_IP=$A DECODE_IP=$V bash $HOME/pd_disagg/scripts/pd_main.sh start $1 $2 > $SP/logs/${2}_start.log 2>&1; log "$2 started: $(health)"; }
shared() { # run tokenizer label sessions concurrency
  wipe || log "$1 wipe before $3 FAILED"
  $PY $SP/victim_recall.py --sessions $4 --prefix 131072 --new 8192 --shared-prefix 8192 --out-tokens 64 --concurrency $5 --seed 71 --run $1 --phase both --settle 60 --label $3 --tokenizer $2 \
    --lb http://$A:8080 --out $R/${1}_$3.jsonl > $R/${1}_$3.out 2>&1
  log "SHARED $1 $3 ($4 sessions, concurrency $5): $($PY $L/strict.py $R/${1}_$3.jsonl); $(health) $(checks $1)"; }
evidence() { PIP=$A DIP=$V bash $L/evidence.sh $1 > $R/evidence_$1.txt 2>&1; log "$1 evidence: $(grep -h 'victim-push\|totals=' $R/evidence_$1.txt | sed 's/.*\(role=\|totals=\)/\1/' | cut -c1-260 | tr '\n' ' ')"; }

for spec in "sglang-1992 pd_1992_qwen_wb.json g1992s_shared_1 $QWEN" "sglang-mvp pd_1991_gptoss_wb_on.json g1991s_shared_1 $GPT"; do
  set -- $spec; tree=$1; recipe=$2; RUN=$3; tok=$4
  stop_pair
  deploy $HOME/$tree || { log "SHARED deploy of $tree failed"; continue; }
  $SSHA "sudo rm -rf $RUNS/$RUN" 2>/dev/null; $SSHV "sudo rm -rf $RUNS/$RUN" 2>/dev/null
  rm -f $R/${RUN}_*.jsonl
  log "SHARED $tree $(git -C $HOME/$tree rev-parse --short HEAD) on g + v7 ($RUN): shared 8k prefix, 16 sessions one at a time, then 20 sessions at 4 concurrent, then 24 at 4"
  start $L/$recipe $RUN
  shared $RUN $tok shared16 16 1
  shared $RUN $tok shared20c 20 4
  shared $RUN $tok shared24c 24 4
  evidence $RUN
  stop_pair
done
log "GOAL SHARED DONE"
