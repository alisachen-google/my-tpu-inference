#!/usr/bin/env bash
# Live validation of the adopt_received_backups fix on g (prefill) + v7 (decode), both trees at their new heads:
#   PR 1992 (Qwen3, write-back, switch on): single-request integrity, mixed sizes, one recall point.
#   hybrid PR (gpt-oss, write-back, switch on): the same, on the model that hit the out-of-memory.
# Both runs on one engine instance per tree, prefill log checked for "out of memory" and scheduler exceptions.
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
stop_pair() { PM stop > /dev/null 2>&1; sleep 25; }
deploy() { ( cd $L; bash deploy_1992.sh $A $1 > deploy_a.log 2>&1 & bash deploy_1992.sh $V $1 > deploy_v7.log 2>&1; wait
    grep -q DEPLOY_OK deploy_a.log && grep -q DEPLOY_OK deploy_v7.log ); }
health() { echo "prefill=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:30000/health) decode=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$V:30000/health) lb=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:8080/health)"; }
exc() { echo "prefill_sched_exc=$($SSHA "sudo grep -c 'Scheduler hit an exception\|out of memory' $RUNS/$1/prefill/server.log" 2>/dev/null) decode_sched_exc=$($SSHV "sudo grep -c 'Scheduler hit an exception\|out of memory' $RUNS/$1/decode/server.log" 2>/dev/null)"; }
adopted() { $SSHA "sudo grep -h 'TP0 EP0. .prefix-pull' $RUNS/$1/prefill/server.log | tail -1 | grep -o \"'adopted_backup_tokens': [0-9]*\"" 2>/dev/null; }
flush_one() { for i in $(seq 1 ${2:-30}); do c=$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $1/flush_cache); [ "$c" = 200 ] && return 0; sleep 10; done; return 1; }
wipe() { flush_one http://$V:30000 && flush_one http://$A:30000; }
start() { timeout 6000 env PREFILL_IP=$A DECODE_IP=$V bash $HOME/pd_disagg/scripts/pd_main.sh start $1 $2 > $SP/logs/${2}_start.log 2>&1; log "$2 started: $(health)"; }
integ() {
  wipe || log "$1 wipe before integrity FAILED"
  timeout 7200 $PY $SP/victim_integrity.py --lb http://$A:8080 --flush http://$A:30000 http://$V:30000 --tokenizer $2 --sessions $3 \
    --prefix 131072 --new 8192 --probes 0 --concurrency 1 --settle 60 --out $R/${1}_integrity1.json > $R/${1}_integrity1.out 2>&1
  log "$1 single-request integrity rc=$? $(grep -E '^SUMMARY' $R/${1}_integrity1.out | cut -c1-600)"; log "$1 after integrity: $(health) $(exc $1) $(adopted $1)"; }
mixed() {
  wipe || log "$1 wipe before mixed FAILED"
  $PY $SP/static_reuse.py --prefixes 8 --visits 3 --prefix 131072 --new 8192 --out-tokens 256 --concurrency 4 --seed 17 --run $1 --label mixed_long --tokenizer $2 \
    --lb http://$A:8080 --prefill-url http://$A:30000 --decode-url http://$V:30000 --out $R/${1}_mixed_long.jsonl > $R/${1}_mixed_long.out 2>&1 & bg=$!
  $PY $SP/victim_recall.py --sessions 48 --prefix 32768 --new 4096 --out-tokens 16 --concurrency 8 --seed 21 --run $1 --phase both --settle 20 --label mixed_short --tokenizer $2 \
    --lb http://$A:8080 --out $R/${1}_mixed_short.jsonl > $R/${1}_mixed_short.out 2>&1
  wait $bg
  log "$1 mixed sizes: short $($PY $L/strict.py $R/${1}_mixed_short.jsonl); long $($PY $L/strict.py $R/${1}_mixed_long.jsonl); $(health) $(exc $1) $(adopted $1)"; }
recall16() { # one recall point: 16 sessions, 128k + 8k, fill then recall
  wipe || log "$1 wipe before recall FAILED"
  $PY $SP/victim_recall.py --sessions 16 --prefix 131072 --new 8192 --out-tokens 64 --concurrency 4 --seed 61 --run $1 --phase both --settle 30 --label recall16 --tokenizer $2 \
    --lb http://$A:8080 --out $R/${1}_recall16.jsonl > $R/${1}_recall16.out 2>&1
  log "$1 recall 16 sessions: $($PY $L/strict.py $R/${1}_recall16.jsonl); $(health) $(exc $1) $(adopted $1)"; }
evidence() { PIP=$A DIP=$V bash $L/evidence.sh $1 > $R/evidence_$1.txt 2>&1; log "$1 evidence: $(grep -h 'victim-push\|totals=' $R/evidence_$1.txt | sed 's/.*\(role=\|totals=\)/\1/' | cut -c1-260 | tr '\n' ' ')"; }

for spec in "sglang-1992 pd_1992_qwen_wb.json g1992f_integ_1 $QWEN" "sglang-mvp pd_1991_gptoss_wb_on.json g1991f_integ_1 $GPT"; do
  set -- $spec; tree=$1; recipe=$2; RUN=$3; tok=$4
  stop_pair
  deploy $HOME/$tree || { log "FIXVAL deploy of $tree failed"; continue; }
  rm -f $R/${RUN}_*.jsonl
  log "FIXVAL $tree $(git -C $HOME/$tree rev-parse --short HEAD) on g + v7 ($RUN): integrity -> recall 16 -> mixed"
  start $L/$recipe $RUN
  integ $RUN $tok 16
  recall16 $RUN $tok
  mixed $RUN $tok
  evidence $RUN
  stop_pair
done
log "GOAL FIXVAL DONE"
