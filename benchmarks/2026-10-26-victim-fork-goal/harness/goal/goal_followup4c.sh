#!/usr/bin/env bash
# After goal_followup3.sh: 1P2D on prefill a + decodes v7 and b (PR 1992 tree, Qwen3, write-back, switch on).
#  W1 through the launcher's LB (random decode per request): recall and static workloads, strict audit.
#  W2 sticky decodes: two extra LBs, one decode each; disjoint sessions on each -> recall from the decode that holds them.
#  W3 single-request integrity through the random LB.
#  W4 decode 2 killed during a recall through the random LB, then restarted.
set -u
L=$HOME/pd_disagg/live; SP=$HOME/pd_disagg/spill; R=$SP/results_goal; A=10.128.15.217; V=10.128.15.239; B=10.128.0.90
PY=$HOME/venv/sglang/bin/python
QWEN=/mnt/data/tt/hf-cache/hub/models--Qwen--Qwen3-30B-A3B-Instruct-2507-FP8/snapshots/5a5a776300a41aaa681dd7ff0106608ef2bc90db
SSHO="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20"
SSHA="$SSHO sa_101411256518727260534@$A"
RUNS=/home/alisachen_google_com/pd_disagg/results/runs
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
log() { echo "$(date -u '+%F %T') $*" >> $L/goal_followup.log; }
PM() { PREFILL_IP=$A DECODE_IP=$V DECODE2_IP=$B bash $HOME/pd_disagg/scripts/pd_1p2d.sh "$@"; }
health() { echo "prefill=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:30000/health) decode1=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$V:30000/health) decode2=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$B:30000/health) lb=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:8080/health)"; }
exc() { echo "prefill_exc=$($SSHA "sudo grep -c 'Scheduler hit an exception' $RUNS/$1/prefill/server.log" 2>/dev/null) decode1_exc=$($SSHO sa_101411256518727260534@$V "sudo grep -c 'Scheduler hit an exception' $RUNS/$1/decode/server.log" 2>/dev/null) decode2_exc=$(grep -c 'Scheduler hit an exception' $RUNS/$1/decode/server.log 2>/dev/null)"; }
flush_one() { for i in $(seq 1 ${2:-30}); do c=$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $1/flush_cache); [ "$c" = 200 ] && return 0; sleep 10; done; return 1; }
wipe() { flush_one http://$V:30000 && flush_one http://$B:30000 && flush_one http://$A:30000; }
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
evidence() { bash $L/evidence.sh $RUN > $R/evidence_${RUN}.txt 2>&1; DIP=$B bash $L/evidence.sh $RUN > $R/evidence_${RUN}_decode2.txt 2>&1
  log "$RUN evidence prefill: $(grep -h 'victim-push. role=prefill\|totals=' $R/evidence_${RUN}.txt | sed 's/.*\(role=\|totals=\)/\1/' | cut -c1-220 | tr '\n' ' ')"
  log "$RUN evidence decode1: $(grep -h 'victim-push. role=decode' $R/evidence_${RUN}.txt | sed 's/.*role=/role=/' | cut -c1-200) | decode2: $(grep -h 'victim-push. role=decode' $R/evidence_${RUN}_decode2.txt | sed 's/.*role=/role=/' | cut -c1-200)"; }

lb() { # port prefill_ip decode_ip: a mini-LB on host a as a transient systemd service (sudo -i would wait for a nohup child and hang the ssh)
  $SSHA "sudo systemd-run --unit=alisachen-lb-$1 --collect --uid=731364623 --gid=731364623 -E HOME=/home/alisachen_google_com --working-directory=/home/alisachen_google_com/sglang-main bash -c 'export SGLANG_ROOT=\$PWD PYTHONPATH=\$PWD/python:\$PWD/sgl-model-gateway/bindings/python/src:\$PWD; exec /home/alisachen_google_com/venv/sglang-main/bin/python -m sglang_router.launch_router --pd-disaggregation --mini-lb --prefill http://$2:30000 8998 --decode http://$3:30000 --host 0.0.0.0 --port $1 > /home/alisachen_google_com/pd_disagg/results/runs/$RUN/lb_$1.log 2>&1'" 2>&1 | tail -1; }
stop_lbs() { $SSHA "sudo systemctl stop 'alisachen-lb-*' 2>/dev/null; sudo pkill -u alisachen_google_com -f 'sglang_router.launch_route[r]'" > /dev/null 2>&1; }

until grep -q "GOAL FOLLOWUP3 DONE" $L/goal_followup.log; do sleep 60; done
RUN=g1992b_1p2d_1
( cd $L; for ip in $A $V $B; do bash deploy_1992.sh $ip $HOME/sglang-1992 > deploy_$ip.log 2>&1 & done; wait )
for ip in $A $V $B; do grep -q DEPLOY_OK $L/deploy_$ip.log || { log "1P2D deploy to $ip failed"; exit 1; }; done
log "1P2D: PR 1992 $(git -C $HOME/sglang-1992 rev-parse --short HEAD) deployed to a, v7 and b"
free_all
timeout 6000 env PREFILL_IP=$A DECODE_IP=$V DECODE2_IP=$B bash $HOME/pd_disagg/scripts/pd_1p2d.sh start $L/pd_1992_qwen_wb_1p2d.json $RUN > $SP/logs/${RUN}_start.log 2>&1
log "1P2D $RUN started: $(health)"
# Two more LBs on the prefill host, one decode each (the launcher's LB on 8080 has both and picks one at random).
lb 8081 $A $V; lb 8082 $A $B
for i in $(seq 1 30); do [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://$A:8081/health)" = 200 ] && [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://$A:8082/health)" = 200 ] && break; sleep 5; done
log "1P2D extra LBs: 8081->decode1 $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://$A:8081/health) 8082->decode2 $(curl -s -m 5 -o /dev/null -w '%{http_code}' http://$A:8082/health)"

log "W1 random decode per request (LB 8080): recall 16 sessions, then static 12 docs"
wipe || log "W1 wipe FAILED"
log "W1 recall: $(recall w1_recall 16 both http://$A:8080); $(hits w1_recall); $(health) $(exc $RUN)"
$PY $SP/static_reuse.py --prefixes 12 --visits 3 --prefix 131072 --new 8192 --out-tokens 256 --concurrency 4 --seed 13 --run $RUN --label w1_static --tokenizer $QWEN --lb http://$A:8080 --prefill-url http://$A:30000 --decode-url http://$V:30000 --out $R/${RUN}_w1_static.jsonl > $R/${RUN}_w1_static.out 2>&1
log "W1 static: $($PY $L/strict.py $R/${RUN}_w1_static.jsonl); $(health) $(exc $RUN)"
evidence

log "W2 sticky decodes: 8 sessions through LB 8081 (decode1) and 8 through LB 8082 (decode2), concurrently"
wipe || log "W2 wipe FAILED"
( recall w2_d1 8 both http://$A:8081 31 > $R/${RUN}_w2_d1.strict ) & p1=$!
recall w2_d2 8 both http://$A:8082 32 > $R/${RUN}_w2_d2.strict; wait $p1
log "W2 decode1 sessions: $(cat $R/${RUN}_w2_d1.strict); $(hits w2_d1) | decode2 sessions: $(cat $R/${RUN}_w2_d2.strict); $(hits w2_d2); $(health) $(exc $RUN)"
evidence

log "W3 single-request integrity through LB 8080"
wipe || log "W3 wipe FAILED"
timeout 7200 $PY $SP/victim_integrity.py --lb http://$A:8080 --flush http://$A:30000 http://$V:30000 http://$B:30000 --tokenizer $QWEN --sessions 16 --prefix 131072 --new 8192 --probes 0 --concurrency 1 --settle 60 --out $R/${RUN}_integrity1.json > $R/${RUN}_integrity1.out 2>&1
log "W3 rc=$? $(grep -E '^SUMMARY' $R/${RUN}_integrity1.out | cut -c1-500); $(health) $(exc $RUN)"

log "W4 decode 2 killed during a recall through LB 8080, then restarted"
wipe || log "W4 wipe FAILED"
log "W4 fill: $(recall w4_fill 12 fill http://$A:8080)"
( recall w4_recall 12 recall http://$A:8080 > $R/${RUN}_w4.strict ) & bg=$!
sleep 15; PM stop-decode2 > /dev/null 2>&1; log "W4 decode 2 stopped"
sleep 60; log "W4 during outage: $(health) $(exc $RUN)"
for i in $(seq 1 90); do kill -0 $bg 2>/dev/null || break; sleep 10; done; kill $bg 2>/dev/null
log "W4 recall during the kill: $(cat $R/${RUN}_w4.strict 2>/dev/null)"
PM start-decode2 $L/pd_1992_qwen_wb_1p2d.json $RUN > $R/${RUN}_w4_restart.log 2>&1; log "W4 decode 2 restarted: $(tail -1 $R/${RUN}_w4_restart.log | cut -c1-100)"
log "W4 after restart: $(recall w4_after 8 both http://$A:8080 7); $(hits w4_after); $(health) $(exc $RUN)"
t0=$(date +%s); wipe; log "W4 flush of all three after the load stopped: rc=$? after $(( $(date +%s)-t0 )) s"
evidence
stop_lbs
PM stop > /dev/null 2>&1
log "GOAL FOLLOWUP4 DONE"
