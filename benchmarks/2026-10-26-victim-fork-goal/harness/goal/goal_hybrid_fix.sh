#!/usr/bin/env bash
# F1D, third attempt: the sweep of the second attempt (g1991d3_on, 205/205) stands; this reruns the edge cases,
# the single-request integrity run and the mixed-size run on g (prefill) + v7 (decode) with the diagnostic hybrid
# tree, pointing edges.sh at the right hosts (EDGE_A/EDGE_V).
set -u
S=/tmp/claude-731364623/-home-alisachen-google-com/8acfc0e7-b491-4704-af65-e66bdf240215/scratchpad; L=$HOME/pd_disagg/live; SP=$HOME/pd_disagg/spill; R=$SP/results_goal; A=10.128.0.175; V=10.128.15.239
PY=$HOME/venv/sglang/bin/python
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
exc() { echo "prefill_exc=$($SSHA "sudo grep -c 'Scheduler hit an exception\|Traceback' $RUNS/$1/prefill/server.log" 2>/dev/null) decode_exc=$($SSHV "sudo grep -c 'Scheduler hit an exception\|Traceback' $RUNS/$1/decode/server.log" 2>/dev/null)"; }
flush_one() { for i in $(seq 1 ${2:-30}); do c=$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $1/flush_cache); [ "$c" = 200 ] && return 0; sleep 10; done; return 1; }
wipe() { flush_one http://$V:30000 && flush_one http://$A:30000; }
start() { timeout 6000 env PREFILL_IP=$A DECODE_IP=$V bash $HOME/pd_disagg/scripts/pd_main.sh start $1 $2 > $SP/logs/${2}_start.log 2>&1; log "$2 started: $(health)"; }
integ() {
  wipe || log "$1 wipe before integrity FAILED"
  timeout 7200 $PY $SP/victim_integrity.py --lb http://$A:8080 --flush http://$A:30000 http://$V:30000 --tokenizer $2 --sessions $3 \
    --prefix 131072 --new 8192 --probes 0 --concurrency 1 --settle 60 --out $R/${1}_integrity1.json > $R/${1}_integrity1.out 2>&1
  log "$1 single-request integrity rc=$? $(grep -E '^SUMMARY' $R/${1}_integrity1.out | cut -c1-600)"; log "$1 after integrity: $(health) $(exc $1)"; }
mixed() {
  wipe || log "$1 wipe before mixed FAILED"
  $PY $SP/static_reuse.py --prefixes 8 --visits 3 --prefix 131072 --new 8192 --out-tokens 256 --concurrency 4 --seed 17 --run $1 --label mixed_long --tokenizer $2 \
    --lb http://$A:8080 --prefill-url http://$A:30000 --decode-url http://$V:30000 --out $R/${1}_mixed_long.jsonl > $R/${1}_mixed_long.out 2>&1 & bg=$!
  $PY $SP/victim_recall.py --sessions 48 --prefix 32768 --new 4096 --out-tokens 16 --concurrency 8 --seed 21 --run $1 --phase both --settle 20 --label mixed_short --tokenizer $2 \
    --lb http://$A:8080 --out $R/${1}_mixed_short.jsonl > $R/${1}_mixed_short.out 2>&1
  wait $bg
  log "$1 mixed sizes: short $($PY $L/strict.py $R/${1}_mixed_short.jsonl); long $($PY $L/strict.py $R/${1}_mixed_long.jsonl); $(health) $(exc $1)"; }
evidence() { PIP=$A DIP=$V bash $L/evidence.sh $1 > $R/evidence_$1.txt 2>&1; log "$1 evidence: $(grep -h 'victim-push\|totals=' $R/evidence_$1.txt | sed 's/.*\(role=\|totals=\)/\1/' | cut -c1-220 | tr '\n' ' ')"; }

RUN=g1991d4_on_1
stop_pair
deploy $S/wt_dbg || { log "F1D-fix deploy of the diagnostic hybrid tree failed"; exit 1; }
rm -f $R/${RUN}_*.jsonl
start $L/pd_1991_gptoss_wb_on_dbg.json $RUN
log "F1D-fix (third attempt): edges -> integrity -> mixed on g (prefill) + v7 (decode), run $RUN"
EDGE_A=$A EDGE_V=$V timeout 14400 bash $L/edges.sh $RUN $L/pd_1991_gptoss_wb_on_dbg.json $GPT >> $L/goal_followup.log 2>&1; log "F1D-fix edges exit $?"
integ $RUN $GPT 16; mixed $RUN $GPT; evidence $RUN
log "F1D drop-decline diagnostics on the prefill: $($SSHA "sudo grep -c drop-decline $RUNS/$RUN/prefill/server.log" 2>/dev/null) lines (run $RUN)"
$SSHA "sudo grep -h drop-decline $RUNS/$RUN/prefill/server.log | head -40" > $R/${RUN}_drop_decline.txt 2>/dev/null
stop_pair
log "GOAL F1D FIX DONE"
