#!/usr/bin/env bash
# Hybrid (SWA + full attention) PR at its current head, gpt-oss-120b on g (prefill) + v7 (decode), write-back on both roles:
#   switch ON  sweep (recall 8/12/16 sessions, static 4/8/12/16 docs) -> edge cases E1-E5 on the same engines -> evidence
#   switch OFF sweep on the same tree (the SWA host tier commit is in both arms)
#   then an on-vs-off table from the POINT lines.
set -u
L=$HOME/pd_disagg/live; SP=$HOME/pd_disagg/spill; R=$SP/results_goal; A=10.128.0.175; V=10.128.15.239
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
exc() { echo "prefill_sched_exc=$($SSHA "sudo grep -c 'Scheduler hit an exception\|out of memory' $RUNS/$1/prefill/server.log" 2>/dev/null) decode_sched_exc=$($SSHV "sudo grep -c 'Scheduler hit an exception\|out of memory' $RUNS/$1/decode/server.log" 2>/dev/null)"; }
adopted() { $SSHA "sudo grep -h 'TP0 EP0. .prefix-pull' $RUNS/$1/prefill/server.log | tail -1 | grep -o \"'adopted_backup_tokens': [0-9]*\"" 2>/dev/null; }
evidence() { PIP=$A DIP=$V bash $L/evidence.sh $1 > $R/evidence_$1.txt 2>&1; log "$1 evidence: $(grep -h 'victim-push\|totals=' $R/evidence_$1.txt | sed 's/.*\(role=\|totals=\)/\1/' | cut -c1-260 | tr '\n' ' ')"; }
sweep() { # name recipe tokenizer recall-list static-list  (CFG=after keeps the engines running afterwards)
  local name=$1; log "sweep $name start ($2)"
  ( cd $SP; export TOK=$3 RECALL="$4" STATIC="$5" A_IP=$A B_IP=$V LAUNCHER=$HOME/pd_disagg/scripts/pd_main.sh CFG=after FLUSH_TRIES=15 KINDS="recall static" NAME=$name RUN=${name}_1 RECIPE=$L/$2
    timeout --signal=TERM 10800 bash chain_pair.sh > logs/goal_${name}_1.log 2>&1; echo "CHAIN_EXIT $?" >> logs/goal_${name}_1.log )
  log "sweep $name end: exit=$(grep CHAIN_EXIT $SP/logs/goal_${name}_1.log | tail -1 | awk '{print $2}') points=$(grep -c '^POINT' $SP/logs/goal_${name}_1.log) strict: $($PY $L/strict.py $R/${name}_1_*.jsonl) $(exc ${name}_1)"; }
table() { # on-name off-name
  python3 - "$SP/logs/goal_$1.log" "$SP/logs/goal_$2.log" <<'EOF' >> $L/goal_followup.log
import json, sys
def pts(p):
    out = {}
    for l in open(p):
        if l.startswith("POINT {"):
            d = json.loads(l[6:]); out[d["label"]] = d
    return out
on, off = pts(sys.argv[1]), pts(sys.argv[2])
print("HYBRID TABLE | point | prefill hit off -> on | TTFT p50 off -> on |")
for lab in on:
    a, b = off.get(lab), on[lab]
    if a is None: continue
    print(f"HYBRID TABLE | {lab} | {100*(a['prefill_hit'] or 0):.1f}% -> {100*(b['prefill_hit'] or 0):.1f}% | {a['ttft50']:.1f} s -> {b['ttft50']:.1f} s |")
EOF
}

GR="131072:8192:8 131072:8192:12 131072:8192:16"
GS="131072:8192:4 131072:8192:8 131072:8192:12 131072:8192:16"
stop_pair
deploy $HOME/sglang-mvp || { log "HYBRID FULL deploy of the hybrid tree failed"; exit 1; }
log "HYBRID FULL hybrid PR $(git -C $HOME/sglang-mvp rev-parse --short HEAD) on g + v7: sweep on -> edges -> sweep off"
rm -f $R/g1991f_on_1_*.jsonl $R/g1991f_off_1_*.jsonl
sweep g1991f_on pd_1991_gptoss_wb_on.json $GPT "$GR" "$GS"
log "HYBRID FULL after on-sweep: $(health) $(adopted g1991f_on_1)"
EDGE_A=$A EDGE_V=$V timeout 14400 bash $L/edges.sh g1991f_on_1 $L/pd_1991_gptoss_wb_on.json $GPT >> $L/goal_followup.log 2>&1; log "HYBRID FULL edges exit $?"
evidence g1991f_on_1
stop_pair
sweep g1991f_off pd_1991_gptoss_wb_off.json $GPT "$GR" "$GS"
stop_pair
table g1991f_on_1 g1991f_off_1
log "GOAL HYBRID FULL DONE"
