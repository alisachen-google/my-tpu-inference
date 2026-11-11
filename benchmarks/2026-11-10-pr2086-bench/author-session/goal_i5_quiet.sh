#!/usr/bin/env bash
# I5 reproduction (output equivalence of recalled vs recomputed 128k+8k requests), gpt-oss-120b on prefill .246 + decode v7,
# the benchmarking agents' E1 procedure: 16 sessions, 6 concurrent 8k probes during fill and settle, recall one at a time,
# flush, recompute, compare 64 greedy tokens. Arms, each on fresh engines:
#   A  ~/sglang-mvp  write-back,     switch on                     (their 13/16)
#   B  ~/sglang-mvp  write-back,     switch on, copy-ahead off     (synchronous write-back backups as upstream)
#   C  ~/sglang-exp  write-back,     switch on                     (prefill SWA window retention left to upstream)
#   D  ~/sglang-mvp  write-through,  switch on                     (their 16/16 control)
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
exc() { echo "prefill_exc=$($SSHA "sudo grep -c 'Scheduler hit an exception\|out of memory\|malformed\|DEADLINE_EXCEEDED' $RUNS/$1/prefill/server.log" 2>/dev/null) decode_exc=$($SSHV "sudo grep -c 'Scheduler hit an exception\|out of memory\|malformed\|DEADLINE_EXCEEDED' $RUNS/$1/decode/server.log" 2>/dev/null) drop_declined=$($SSHA "sudo grep -c 'subtree drop declined' $RUNS/$1/prefill/server.log" 2>/dev/null) jit_rebuilds=$($SSHA "sudo grep -c 'stale or broken JIT' $RUNS/$1/prefill/server.log" 2>/dev/null)"; }
evidence() { PIP=$A DIP=$V bash $L/evidence.sh $1 > $R/evidence_$1.txt 2>&1; log "$1 evidence: $(grep -h 'victim-push\|totals=' $R/evidence_$1.txt | sed 's/.*\(role=\|totals=\)/\1/' | cut -c1-260 | tr '\n' ' ')"; }
keep_logs() { mkdir -p $SP/prefill_logs $SP/decode_logs
  $SSHA "sudo gzip -c $RUNS/$1/prefill/server.log" > $SP/prefill_logs/$1_a.log.gz 2>/dev/null
  $SSHV "sudo gzip -c $RUNS/$1/decode/server.log" > $SP/decode_logs/$1_v.log.gz 2>/dev/null
  log "$1 logs kept: $(ls -la $SP/prefill_logs/$1_a.log.gz $SP/decode_logs/$1_v.log.gz | awk '{print $5}' | tr '\n' ' ')"; }
start() { timeout 6000 env PREFILL_IP=$A DECODE_IP=$V bash $HOME/pd_disagg/scripts/pd_main.sh start $1 $2 > $SP/logs/${2}_start.log 2>&1; log "$2 started: $(health)"; }
e1() { # run: the agents' E1 (fresh engines): 16 sessions 128k+8k, 6 probes of 8k during fill/settle, recall one at a time, flush, verify
  timeout 7200 $PY $SP/victim_integrity_quiet.py --lb http://$A:8080 --flush http://$A:30000 http://$V:30000 --tokenizer $GPT --sessions 16 \
    --prefix 131072 --new 8192 --out-tokens 64 --probes 6 --probe-len 8192 --probe-out 128 --concurrency 1 --settle 90 --seed 11 \
    --out $R/${1}_e1.json > $R/${1}_e1.out 2>&1
  log "$1 E1 rc=$? $(grep -E '^SUMMARY' $R/${1}_e1.out | cut -c1-700)"
  log "$1 E1 per-session: $(python3 - $R/${1}_e1.json <<'EOF'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
rec={r["session"]:r for r in rows if r.get("phase")=="recall"}; ver={r["session"]:r for r in rows if r.get("phase")=="verify"}
out=[]
for s in sorted(rec):
    a,b=rec[s],ver.get(s)
    if b is None or a.get("out") is None or b.get("out") is None: out.append(f"s{s}:?"); continue
    first=next((i for i,(x,y) in enumerate(zip(a["out"],b["out"])) if x!=y), None)
    d=a.get("details") or {}
    out.append(f"s{s}:{'ok' if first is None else 'diff@'+str(first)}/{a.get('cached')}({d.get('host',0)}h)")
print(" ".join(out))
EOF
)"
  log "$1 after E1: $(health) $(exc $1)"; }

for spec in "sglang-head pd_1991_gptoss_wb_on.json i5qh_head_wb_on" "sglang-mvp pd_1991_gptoss_wb_on.json i5qf_fix_wb_on" "sglang-mvp pd_1991_gptoss_wb_on_noca.json i5qg_fix_wb_on_noca" "sglang-mvp pd_1991_gptoss_wt_on.json i5qw_fix_wt_on"; do
  set -- $spec; tree=$1; recipe=$2; RUN=$3
  stop_pair
  deploy $HOME/$tree || { log "I5 deploy of $tree failed"; continue; }
  $SSHA "sudo rm -rf $RUNS/$RUN" 2>/dev/null; $SSHV "sudo rm -rf $RUNS/$RUN" 2>/dev/null
  rm -f $R/${RUN}_e1.json
  log "I5 $tree $(git -C $HOME/$tree rev-parse --short HEAD)$(git -C $HOME/$tree diff --quiet || echo '+exp') $recipe on .246 + v7 ($RUN): E1 on fresh engines"
  start $L/$recipe $RUN
  e1 $RUN
  evidence $RUN
  keep_logs $RUN
  stop_pair
done
log "GOAL I5 QUIET DONE"
