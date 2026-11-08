#!/usr/bin/env bash
# After goal_followup5.sh: 2P2D on prefills a + b and decodes v7 + g (PR 1992 tree, Qwen3, write-back, switch on).
#  Y1 through the launcher's LB (random prefill and random decode per request): recall and static workloads.
#  Y2 deterministic routes through extra LBs: fill via (a, v7); return via (b, v7) = other prefill, same decode (recall
#     from decode DRAM into a prefill that never saw the session); then via (a, g) = same prefill, other decode.
#  Y3 single-request integrity through the random LB.
#  Y4 decode g killed while recalls are in flight, then restarted.  Y5 prefill b killed while pushes are in flight, then restarted.
#  Y6 flush of all four under load (refused), then once the load stopped.
set -u
L=$HOME/pd_disagg/live; SP=$HOME/pd_disagg/spill; R=$SP/results_goal; A=10.128.15.217; V=10.128.15.239; B=10.128.0.90; G=10.128.0.175
PY=$HOME/venv/sglang/bin/python
QWEN=/mnt/data/tt/hf-cache/hub/models--Qwen--Qwen3-30B-A3B-Instruct-2507-FP8/snapshots/5a5a776300a41aaa681dd7ff0106608ef2bc90db
SSHO="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20"
SSHA="$SSHO sa_101411256518727260534@$A"
RUNS=/home/alisachen_google_com/pd_disagg/results/runs
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
log() { echo "$(date -u '+%F %T') $*" >> $L/goal_followup.log; }
PM() { PREFILL_IPS="$A $B" DECODE_IPS="$V $G" bash $HOME/pd_disagg/scripts/pd_group.sh "$@"; }
hc() { curl -s -m 10 -o /dev/null -w '%{http_code}' $1; }
health() { echo "prefill_a=$(hc http://$A:30000/health) prefill_b=$(hc http://$B:30000/health) decode_v7=$(hc http://$V:30000/health) decode_g=$(hc http://$G:30000/health) lb=$(hc http://$A:8080/health)"; }
cnt() { $SSHO sa_101411256518727260534@$1 "sudo grep -c 'Scheduler hit an exception' $RUNS/$2/$3/server.log" 2>/dev/null; }
exc() { echo "exc: a=$(cnt $A $1 prefill) b=$(grep -c 'Scheduler hit an exception' $RUNS/$1/prefill/server.log 2>/dev/null) v7=$(cnt $V $1 decode) g=$(cnt $G $1 decode)"; }
flush_one() { for i in $(seq 1 ${2:-30}); do c=$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $1/flush_cache); [ "$c" = 200 ] && return 0; sleep 10; done; return 1; }
wipe() { flush_one http://$V:30000 && flush_one http://$G:30000 && flush_one http://$A:30000 && flush_one http://$B:30000; }
free_all() { for ip in $A $V $B $G; do while true; do
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
evidence() { bash $L/evidence.sh $RUN > $R/evidence_${RUN}.txt 2>&1; PIP=$B DIP=$G bash $L/evidence.sh $RUN > $R/evidence_${RUN}_bg.txt 2>&1
  log "$RUN evidence prefill a: $(grep -h 'victim-push. role=prefill\|totals=' $R/evidence_${RUN}.txt | sed 's/.*\(role=\|totals=\)/\1/' | cut -c1-200 | tr '\n' ' ')"
  log "$RUN evidence prefill b: $(grep -h 'victim-push. role=prefill\|totals=' $R/evidence_${RUN}_bg.txt | sed 's/.*\(role=\|totals=\)/\1/' | cut -c1-200 | tr '\n' ' ')"
  log "$RUN evidence decode v7: $(grep -h 'victim-push. role=decode' $R/evidence_${RUN}.txt | sed 's/.*role=/role=/' | cut -c1-160) | decode g: $(grep -h 'victim-push. role=decode' $R/evidence_${RUN}_bg.txt | sed 's/.*role=/role=/' | cut -c1-160)"; }
lb() { # port prefill_ip decode_ip: a mini-LB on host a as a transient systemd service (sudo -i would wait for a nohup child and hang the ssh)
  $SSHA "sudo systemd-run --unit=alisachen-lb-$1 --collect --uid=731364623 --gid=731364623 -E HOME=/home/alisachen_google_com --working-directory=/home/alisachen_google_com/sglang-main bash -c 'export SGLANG_ROOT=\$PWD PYTHONPATH=\$PWD/python:\$PWD/sgl-model-gateway/bindings/python/src:\$PWD; exec /home/alisachen_google_com/venv/sglang-main/bin/python -m sglang_router.launch_router --pd-disaggregation --mini-lb --prefill http://$2:30000 8998 --decode http://$3:30000 --host 0.0.0.0 --port $1 > /home/alisachen_google_com/pd_disagg/results/runs/$RUN/lb_$1.log 2>&1'" 2>&1 | tail -1; }
stop_lbs() { $SSHA "sudo systemctl stop 'alisachen-lb-*' 2>/dev/null; sudo pkill -u alisachen_google_com -f 'sglang_router.launch_route[r]'" > /dev/null 2>&1; }

until grep -q "GOAL FOLLOWUP5 DONE" $L/goal_followup.log; do sleep 60; done
RUN=g1992b_2p2d_1
( cd $L; bash deploy_1992.sh $G $HOME/sglang-1992 > deploy_$G.log 2>&1 ); grep -q DEPLOY_OK $L/deploy_$G.log || { log "2P2D deploy to g failed"; exit 1; }
log "2P2D: PR 1992 $(git -C $HOME/sglang-1992 rev-parse --short HEAD) on a, b, v7 (from the earlier stages) and g"
free_all
timeout 7200 env PREFILL_IPS="$A $B" DECODE_IPS="$V $G" bash $HOME/pd_disagg/scripts/pd_group.sh start $L/pd_1992_qwen_wb_2p2d.json $RUN > $SP/logs/${RUN}_start.log 2>&1
log "2P2D $RUN started: $(health)"
lb 8081 $A $V; lb 8082 $B $G; lb 8083 $A $G; lb 8084 $B $V
for i in $(seq 1 30); do ok=1; for p in 8081 8082 8083 8084; do [ "$(hc http://$A:$p/health)" = 200 ] || ok=0; done; [ $ok = 1 ] && break; sleep 5; done
log "2P2D extra LBs: 8081(a,v7)=$(hc http://$A:8081/health) 8082(b,g)=$(hc http://$A:8082/health) 8083(a,g)=$(hc http://$A:8083/health) 8084(b,v7)=$(hc http://$A:8084/health)"

log "Y1 random prefill and decode per request (LB 8080): recall 16 sessions, then static 12 docs"
wipe || log "Y1 wipe FAILED"
log "Y1 recall: $(recall y1_recall 16 both http://$A:8080); $(hits y1_recall); $(health) $(exc $RUN)"
$PY $SP/static_reuse.py --prefixes 12 --visits 3 --prefix 131072 --new 8192 --out-tokens 256 --concurrency 4 --seed 13 --run $RUN --label y1_static --tokenizer $QWEN --lb http://$A:8080 --prefill-url http://$A:30000 --decode-url http://$V:30000 --out $R/${RUN}_y1_static.jsonl > $R/${RUN}_y1_static.out 2>&1
log "Y1 static: $($PY $L/strict.py $R/${RUN}_y1_static.jsonl); $(health) $(exc $RUN)"
evidence

log "Y2 deterministic routes: fill 12 sessions via (a,v7); return via (b,v7); return via (a,g); return via (b,g)"
wipe || log "Y2 wipe FAILED"
log "Y2 fill (a,v7): $(recall y2_fill 12 fill http://$A:8081 51)"
log "Y2 return (b,v7) other prefill, same decode: $(recall y2_b_v7 12 recall http://$A:8084 51); $(hits y2_b_v7)"
log "Y2 return (a,g) same prefill, other decode: $(recall y2_a_g 12 recall http://$A:8083 51); $(hits y2_a_g)"
log "Y2 return (b,g) other prefill, other decode: $(recall y2_b_g 12 recall http://$A:8082 51); $(hits y2_b_g); $(health) $(exc $RUN)"
evidence

log "Y3 single-request integrity through LB 8080"
wipe || log "Y3 wipe FAILED"
timeout 7200 $PY $SP/victim_integrity.py --lb http://$A:8080 --flush http://$A:30000 http://$B:30000 http://$V:30000 http://$G:30000 --tokenizer $QWEN --sessions 16 --prefix 131072 --new 8192 --probes 0 --concurrency 1 --settle 60 --out $R/${RUN}_integrity1.json > $R/${RUN}_integrity1.out 2>&1
log "Y3 rc=$? $(grep -E '^SUMMARY' $R/${RUN}_integrity1.out | cut -c1-500); $(health) $(exc $RUN)"

log "Y4 decode g killed during a recall through LB 8080, then restarted"
wipe || log "Y4 wipe FAILED"
log "Y4 fill: $(recall y4_fill 12 fill http://$A:8080)"
( recall y4_recall 12 recall http://$A:8080 > $R/${RUN}_y4.strict ) & bg=$!
sleep 15; PM stop-host $G > /dev/null 2>&1; log "Y4 decode g stopped"
sleep 60; log "Y4 during outage: $(health) $(exc $RUN)"
for i in $(seq 1 90); do kill -0 $bg 2>/dev/null || break; sleep 10; done; kill $bg 2>/dev/null
log "Y4 recall during the kill: $(cat $R/${RUN}_y4.strict 2>/dev/null)"
PM start-host $G $L/pd_1992_qwen_wb_2p2d.json $RUN > $R/${RUN}_y4_restart.log 2>&1; log "Y4 decode g restarted: $(tail -1 $R/${RUN}_y4_restart.log | cut -c1-100)"
log "Y4 after restart: $(recall y4_after 8 both http://$A:8080 7); $(hits y4_after); $(health) $(exc $RUN)"

log "Y5 prefill b killed while pushes are in flight (fill 16 sessions through LB 8080), then restarted"
wipe || log "Y5 wipe FAILED"
( recall y5_fill 16 fill http://$A:8080 > $R/${RUN}_y5.strict ) & bg=$!
sleep 45; PM stop-host $B > /dev/null 2>&1; log "Y5 prefill b stopped"
sleep 30; kill $bg 2>/dev/null; log "Y5 during outage: $(health) $(exc $RUN)"
flush_one http://$V:30000 30 && flush_one http://$G:30000 30 && log "Y5 both decodes flushable (landings of the dead prefill released)" || log "Y5 a decode flush REFUSED for 5 min"
PM start-host $B $L/pd_1992_qwen_wb_2p2d.json $RUN > $R/${RUN}_y5_restart.log 2>&1; log "Y5 prefill b restarted: $(tail -1 $R/${RUN}_y5_restart.log | cut -c1-100)"
log "Y5 after restart: $(recall y5_after 8 both http://$A:8080 9); $(hits y5_after); $(health) $(exc $RUN)"

log "Y6 flush of all four under load (static 8 docs through LB 8080, flush 30 s in), then once the load stopped"
wipe || log "Y6 wipe FAILED"
( $PY $SP/static_reuse.py --prefixes 8 --visits 3 --prefix 131072 --new 8192 --out-tokens 256 --concurrency 4 --seed 17 --run $RUN --label y6_static --tokenizer $QWEN --lb http://$A:8080 --prefill-url http://$A:30000 --decode-url http://$V:30000 --out $R/${RUN}_y6_static.jsonl > $R/${RUN}_y6_static.out 2>&1 ) & bg=$!
sleep 30; codes=""; for u in $A $B $V $G; do codes="$codes $(curl -s -m 60 -o /dev/null -w '%{http_code}' -X POST http://$u:30000/flush_cache)"; done; wait $bg
t0=$(date +%s); wipe; log "Y6 flush codes under load (a b v7 g):$codes; requests $($PY $L/strict.py $R/${RUN}_y6_static.jsonl); flush of all four after the load stopped rc=$? after $(( $(date +%s)-t0 )) s; $(health) $(exc $RUN)"
evidence
stop_lbs
PM stop > /dev/null 2>&1
log "GOAL FOLLOWUP6 DONE"
