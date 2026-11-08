#!/usr/bin/env bash
# Follow-up to goal_queue.sh on prefill a + decode v7. Starts once the queue has logged "GOAL QUEUE DONE".
# The queue's sweeps ran before the second round of review fixes; F1 and F2 repeat the switch-on arm on the fixed heads.
#  F1 hybrid PR tree, gpt-oss, write-back, switch on: sweep, edge cases, single-request integrity, mixed request sizes.
#  F2 PR 1992 tree, Qwen3, write-back, switch on: sweep, edge cases, single-request integrity, mixed request sizes.
#  F3 PR 1992 tree: the switch on for one role only must fail requests by name, not hang (both directions).
#  F4 PR 1992 tree, Qwen3, write-through, switch on: short sweep, single-request integrity.
set -u
L=$HOME/pd_disagg/live; SP=$HOME/pd_disagg/spill; R=$SP/results_goal; A=10.128.15.217; V=10.128.15.239
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
wait_free() { while true; do
    h=$($SSHA "sudo fuser -v /dev/vfio/0 2>&1 | awk 'NR>1{print \$(NF-3)}' | sort -u | grep -v alisachen | tr '\n' ' '" 2>/dev/null); rc=$?
    [ $rc -eq 0 ] && [ -z "$(echo $h | tr -d ' ')" ] && return 0; sleep 120; done; }
deploy() { ( cd $L; bash deploy_1992.sh $A $1 > deploy_a.log 2>&1 & bash deploy_1992.sh $V $1 > deploy_v7.log 2>&1; wait
    grep -q DEPLOY_OK deploy_a.log && grep -q DEPLOY_OK deploy_v7.log ); }
health() { echo "prefill=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:30000/health) decode=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$V:30000/health) lb=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:8080/health)"; }
exc() { echo "prefill_exc=$($SSHA "sudo grep -c 'Scheduler hit an exception\|Traceback' $RUNS/$1/prefill/server.log" 2>/dev/null) decode_exc=$($SSHV "sudo grep -c 'Scheduler hit an exception\|Traceback' $RUNS/$1/decode/server.log" 2>/dev/null)"; }
flush_one() { for i in $(seq 1 ${2:-30}); do c=$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $1/flush_cache); [ "$c" = 200 ] && return 0; sleep 10; done; return 1; }
wipe() { flush_one http://$V:30000 && flush_one http://$A:30000; }
start() { # recipe run
  wait_free; timeout 6000 env PREFILL_IP=$A DECODE_IP=$V bash $HOME/pd_disagg/scripts/pd_main.sh start $1 $2 > $SP/logs/${2}_start.log 2>&1
  log "$2 started: $(health)"; }
integ() { # run tokenizer sessions: one request at a time, no probes -> recalled output must equal the recompute
  wipe || log "$1 wipe before integrity FAILED"
  timeout 7200 $PY $SP/victim_integrity.py --lb http://$A:8080 --flush http://$A:30000 http://$V:30000 --tokenizer $2 --sessions $3 \
    --prefix 131072 --new 8192 --probes 0 --concurrency 1 --settle 60 --out $R/${1}_integrity1.json > $R/${1}_integrity1.out 2>&1
  log "$1 single-request integrity rc=$? $(grep -E '^SUMMARY' $R/${1}_integrity1.out | cut -c1-600)"; log "$1 after integrity: $(health) $(exc $1)"; }
mixed() { # run tokenizer: many short sessions (32k+4k, fill then recall) while long documents (128k+8k) are revisited
  wipe || log "$1 wipe before mixed FAILED"
  $PY $SP/static_reuse.py --prefixes 8 --visits 3 --prefix 131072 --new 8192 --out-tokens 256 --concurrency 4 --seed 17 --run $1 --label mixed_long --tokenizer $2 \
    --lb http://$A:8080 --prefill-url http://$A:30000 --decode-url http://$V:30000 --out $R/${1}_mixed_long.jsonl > $R/${1}_mixed_long.out 2>&1 & bg=$!
  $PY $SP/victim_recall.py --sessions 48 --prefix 32768 --new 4096 --out-tokens 16 --concurrency 8 --seed 21 --run $1 --phase both --settle 20 --label mixed_short --tokenizer $2 \
    --lb http://$A:8080 --out $R/${1}_mixed_short.jsonl > $R/${1}_mixed_short.out 2>&1
  wait $bg; t0=$(date +%s)
  flush_one http://$A:30000 30; fp=$?; t1=$(date +%s); flush_one http://$V:30000 30; fv=$?
  log "$1 flush after the load stopped: prefill rc=$fp after $((t1-t0)) s, decode rc=$fv after $(( $(date +%s)-t1 )) s"
  log "$1 mixed sizes: short $($PY $L/strict.py $R/${1}_mixed_short.jsonl); long $($PY $L/strict.py $R/${1}_mixed_long.jsonl); $(health) $(exc $1)"; }
evidence() { bash $L/evidence.sh $1 > $R/evidence_$1.txt 2>&1; log "$1 evidence: $(grep -h 'victim-push\|totals=' $R/evidence_$1.txt | sed 's/.*\(role=\|totals=\)/\1/' | cut -c1-220 | tr '\n' ' ')"; }
ask() { # run label: one short request through the LB, 5 minute limit; logs the http code and the first bytes of the body
  code=$(curl -s -m 300 -o $R/${1}_$2.body -w '%{http_code} in %{time_total}s' -H 'Content-Type: application/json' -X POST http://$A:8080/generate \
    -d '{"text": "The capital of France is", "sampling_params": {"temperature": 0, "max_new_tokens": 8}}')
  log "$1 $2: http $code body: $(head -c 300 $R/${1}_$2.body | tr '\n' ' ')"; }
sweep() { # name recipe tokenizer recall-list static-list
  local name=$1; log "sweep $name start ($2)"; wait_free
  ( cd $SP; export TOK=$3 RECALL="$4" STATIC="$5" A_IP=$A B_IP=$V LAUNCHER=$HOME/pd_disagg/scripts/pd_main.sh CFG=after FLUSH_TRIES=15 KINDS="recall static" NAME=$name RUN=${name}_1 RECIPE=$L/$2
    timeout --signal=TERM 10800 bash chain_pair.sh > logs/goal_${name}_1.log 2>&1; echo "CHAIN_EXIT $?" >> logs/goal_${name}_1.log )
  bash $L/evidence.sh ${name}_1 > $R/evidence_${name}.txt 2>&1
  log "sweep $name end: exit=$(grep CHAIN_EXIT $SP/logs/goal_${name}_1.log | tail -1 | awk '{print $2}') points=$(grep -c '^POINT' $SP/logs/goal_${name}_1.log) strict: $($PY $L/strict.py $R/${name}_1_*.jsonl)"; }

QR="131072:8192:8 131072:8192:12 131072:8192:16 131072:8192:20 131072:8192:24"
QS="131072:8192:4 131072:8192:8 131072:8192:12 131072:8192:16 131072:8192:20 131072:8192:24 131072:8192:28"
GR="131072:8192:8 131072:8192:12 131072:8192:16"
GS="131072:8192:4 131072:8192:8 131072:8192:12 131072:8192:16"
log "waiting for the goal queue"
until grep -q "GOAL QUEUE DONE\|deploy of PR 1991 failed" $L/goal_queue.log; do sleep 60; done
stop_pair

for step in ${STEPS:-F1 F2 F3 F4}; do
case $step in
F1) deploy $HOME/sglang-mvp || { log "F1 deploy of the hybrid tree failed"; continue; }
  log "F1 hybrid tree $(git -C $HOME/sglang-mvp rev-parse --short HEAD) deployed"
  sweep g1991b_on pd_1991_gptoss_wb_on.json $GPT "$GR" "$GS"
  timeout 14400 bash $L/edges.sh g1991b_on_1 $L/pd_1991_gptoss_wb_on.json $GPT >> $L/goal_followup.log 2>&1; log "F1 edges exit $?"
  integ g1991b_on_1 $GPT 16; mixed g1991b_on_1 $GPT; evidence g1991b_on_1; stop_pair ;;
F2) deploy $HOME/sglang-1992 || { log "F2 deploy of PR 1992 failed"; continue; }
  log "F2 PR 1992 tree $(git -C $HOME/sglang-1992 rev-parse --short HEAD) deployed"
  sweep g1992b_on pd_1992_qwen_wb.json $QWEN "$QR" "$QS"
  timeout 14400 bash $L/edges.sh g1992b_on_1 $L/pd_1992_qwen_wb.json $QWEN >> $L/goal_followup.log 2>&1; log "F2 edges exit $?"
  integ g1992b_on_1 $QWEN 16; mixed g1992b_on_1 $QWEN; evidence g1992b_on_1; stop_pair ;;
F3) # the switch on for one role only
  for dir in "pd_1992_qwen_wb.json pd_1992_qwen_wb_off.json pon_doff" "pd_1992_qwen_wb_off.json pd_1992_qwen_wb.json poff_don"; do
    set -- $dir; run=g1992_mismatch_$3; wait_free
    ( PM start-decode $L/$2 $run > $SP/logs/${run}_decode_start.log 2>&1 ) & d=$!
    PM start-prefill $L/$1 $run > $SP/logs/${run}_prefill_start.log 2>&1; wait $d
    log "$run started (prefill $1, decode $2): $(health)"
    ask $run first; ask $run second
    log "$run prefill log: $($SSHA "sudo grep -h 'is on for' $RUNS/$run/prefill/server.log | head -1 | cut -c1-300") | decode log: $($SSHV "sudo grep -h 'is on for\|refus' $RUNS/$run/decode/server.log | head -1 | cut -c1-300")"
    log "$run after: $(health) $(exc $run)"; stop_pair
  done ;;
F4) sweep g1992_wt pd_1992_qwen_wt.json $QWEN "131072:8192:12 131072:8192:16 131072:8192:20" "131072:8192:12 131072:8192:16 131072:8192:24"
  integ g1992_wt_1 $QWEN 16; evidence g1992_wt_1; stop_pair ;;
esac
done
log "GOAL FOLLOWUP DONE"
