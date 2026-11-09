#!/usr/bin/env bash
# After goal_followup4.sh: 2P1D on prefills a + b and decode v7 (PR 1992 tree, Qwen3, write-back, switch on).
#  X1 through the launcher's LB (random prefill per request): recall and static workloads; a session's turns land on
#     either prefill, so the decode's offer serves recalls into a prefill that never saw the session.
#  X2 deterministic cross-prefill recall: fill through prefill a only (LB 8081), recall through prefill b only (LB 8082).
#  X3 single-request integrity through the random LB.
#  X4 prefill b killed while recalls are in flight through the random LB, then restarted.
#  X5 the decode flushed while both prefills push (refused, then retried once the load stopped).
set -u
L=$HOME/pd_disagg/live; SP=$HOME/pd_disagg/spill; R=$SP/results_goal; A=10.128.0.246; V=10.128.15.239; B=10.128.0.175
PY=$HOME/venv/sglang/bin/python
QWEN=/mnt/data/tt/hf-cache/hub/models--Qwen--Qwen3-30B-A3B-Instruct-2507-FP8/snapshots/5a5a776300a41aaa681dd7ff0106608ef2bc90db
SSHO="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20"
SSHA="$SSHO sa_101411256518727260534@$A"
RUNS=/home/alisachen_google_com/pd_disagg/results/runs
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
deploy_all() { ( cd $L; for ip in "$@"; do bash deploy_1992.sh $ip $HOME/sglang-1992 > deploy_$ip.log 2>&1 & done; wait ); for ip in "$@"; do grep -q DEPLOY_OK $L/deploy_$ip.log || { log "deploy of PR 1992 to $ip failed"; return 1; }; done; log "PR 1992 $(git -C $HOME/sglang-1992 rev-parse --short HEAD) deployed to: $*"; }
log() { echo "$(date -u '+%F %T') $*" >> $L/goal_followup.log; }
PM() { PREFILL_IPS="$A $B" DECODE_IPS="$V" bash $HOME/pd_disagg/scripts/pd_group.sh "$@"; }
health() { echo "prefill_a=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:30000/health) prefill_b=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$B:30000/health) decode=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$V:30000/health) lb=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:8080/health)"; }
exc() { echo "prefill_a_exc=$($SSHA "sudo grep -c 'Scheduler hit an exception' $RUNS/$1/prefill/server.log" 2>/dev/null) prefill_b_exc=$(grep -c 'Scheduler hit an exception' $RUNS/$1/prefill/server.log 2>/dev/null) decode_exc=$($SSHO sa_101411256518727260534@$V "sudo grep -c 'Scheduler hit an exception' $RUNS/$1/decode/server.log" 2>/dev/null)"; }
flush_one() { for i in $(seq 1 ${2:-30}); do c=$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $1/flush_cache); [ "$c" = 200 ] && return 0; sleep 10; done; return 1; }
wipe() { flush_one http://$V:30000 && flush_one http://$A:30000 && flush_one http://$B:30000; }
free_all() { for ip in $A $V $B; do while true; do
    h=$($SSHO sa_101411256518727260534@$ip "sudo fuser -v /dev/vfio/0 2>&1 | awk 'NR>1{print \$(NF-3)}' | sort -u | grep -v alisachen | tr '\n' ' '" 2>/dev/null); rc=$?
    [ $rc -eq 0 ] && [ -z "$(echo $h | tr -d ' ')" ] && break; log "waiting for TPU on $ip (held by $h)"; sleep 120; done; done; }
recall() { # label sessions phase lb seed
  $PY $SP/victim_recall.py --sessions $2 --prefix 131072 --new 8192 --out-tokens 16 --concurrency 4 --seed ${5:-5} --run $RUN --phase $3 --settle 20 --label $1 --tokenizer $QWEN --lb $4 --out $R/${RUN}_$1.jsonl > $R/${RUN}_$1.out 2>&1
  $PY $L/strict.py $R/${RUN}_$1.jsonl; }
hits() { $PY - $R/${RUN}_$1.jsonl <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.startswith('{')]
rec=[r for r in rows if r.get('phase')=='recall' and r.get('reusable_tokens')]
if rec: print(f"recall-phase prefix hit {100*sum(r.get('cached_tokens') or 0 for r in rec)/sum(r['reusable_tokens'] for r in rec):.1f}% over {len(rec)} requests")
PY
}
evidence() { PIP=$A DIP=$V bash $L/evidence.sh $RUN > $R/evidence_${RUN}.txt 2>&1; PIP=$B DIP=$V bash $L/evidence.sh $RUN > $R/evidence_${RUN}_prefill_b.txt 2>&1
  log "$RUN evidence prefill a: $(grep -h 'victim-push. role=prefill\|totals=' $R/evidence_${RUN}.txt | sed 's/.*\(role=\|totals=\)/\1/' | cut -c1-200 | tr '\n' ' ')"
  log "$RUN evidence prefill b: $(grep -h 'victim-push. role=prefill\|totals=' $R/evidence_${RUN}_prefill_b.txt | sed 's/.*\(role=\|totals=\)/\1/' | cut -c1-200 | tr '\n' ' ')"
  log "$RUN evidence decode: $(grep -h 'victim-push. role=decode\|refused' $R/evidence_${RUN}.txt | sed 's/.*role=/role=/' | cut -c1-200 | tr '\n' ' ')"; }

lb() { # port prefill_ip decode_ip: a mini-LB on host a as a transient systemd service (sudo -i would wait for a nohup child and hang the ssh)
  $SSHA "sudo systemd-run --unit=alisachen-lb-$1 --collect --uid=731364623 --gid=731364623 -E HOME=/home/alisachen_google_com --working-directory=/home/alisachen_google_com/sglang-main bash -c 'export SGLANG_ROOT=\$PWD PYTHONPATH=\$PWD/python:\$PWD/sgl-model-gateway/bindings/python/src:\$PWD; exec /home/alisachen_google_com/venv/sglang-main/bin/python -m sglang_router.launch_router --pd-disaggregation --mini-lb --prefill http://$2:30000 8998 --decode http://$3:30000 --host 0.0.0.0 --port $1 > /home/alisachen_google_com/pd_disagg/results/runs/$RUN/lb_$1.log 2>&1'" 2>&1 | tail -1; }
stop_lbs() { $SSHA "sudo systemctl stop 'alisachen-lb-*' 2>/dev/null; sudo pkill -u alisachen_google_com -f 'sglang_router.launch_route[r]'" > /dev/null 2>&1; }

deploy_all $A $B $V || exit 1
RUN=g1992b_2p1d_x2b
deploy_all $A $B $V || exit 1
free_all
rm -f $R/${RUN}_*.jsonl
timeout 6000 env PREFILL_IPS="$A $B" DECODE_IPS="$V" bash $HOME/pd_disagg/scripts/pd_group.sh start $L/pd_1992_qwen_wb_2p1d.json $RUN > $SP/logs/${RUN}_start.log 2>&1
log "2P1D-X2b $RUN started: $(health)"
lb 8081 $A $V; lb 8082 $B $V
for i in $(seq 1 30); do [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://$A:8081/health)" = 200 ] && [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://$A:8082/health)" = 200 ] && break; sleep 5; done
decode_landed() { $SSHO sa_101411256518727260534@$V "sudo grep -h 'victim-push. role=decode' $RUNS/$RUN/decode/server.log | grep 'TP0 ' | tail -1 | grep -o 'landed=[0-9]*'" 2>/dev/null; }
log "X2b cross-prefill recall with host pressure: 20 sessions filled through prefill a, then 24 short requests keep a serving while it pushes, then returns through prefill b, then through a"
wipe || log "X2b wipe FAILED"
log "X2b fill via a (20 sessions): $(recall x2b_fill_a 20 fill http://$A:8081 61); decode $(decode_landed)"
$PY $SP/victim_recall.py --sessions 24 --prefix 32768 --new 4096 --out-tokens 16 --concurrency 8 --seed 62 --run $RUN --phase fill --label x2b_keepalive --tokenizer $QWEN --lb http://$A:8081 --out $R/${RUN}_x2b_keepalive.jsonl > $R/${RUN}_x2b_keepalive.out 2>&1
log "X2b keep-alive on a: $($PY $L/strict.py $R/${RUN}_x2b_keepalive.jsonl); decode $(decode_landed)"
log "X2b return via b (cross-prefill): $(recall x2b_recall_b 20 recall http://$A:8082 61); $(hits x2b_recall_b); decode $(decode_landed)"
log "X2b return via a: $(recall x2b_recall_a 20 recall http://$A:8081 61); $(hits x2b_recall_a); $(health) $(exc $RUN)"
evidence
stop_lbs
PM stop > /dev/null 2>&1
log "GOAL 2P1D X2B DONE"
