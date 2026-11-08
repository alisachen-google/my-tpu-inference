#!/usr/bin/env bash
# Edge cases on a running pair (prefill a, decode v7) with the offload switch on. edges.sh <RUN> <recipe> <tokenizer>
RUN=${1:?}; RECIPE=${2:?}; TOK=${3:?}
A=${EDGE_A:-10.128.15.217}; V=${EDGE_V:-10.128.15.239}; SP=$HOME/pd_disagg/spill; PY=$HOME/venv/sglang/bin/python; R=$SP/results_goal
PM="env PREFILL_IP=$A DECODE_IP=$V bash $HOME/pd_disagg/scripts/pd_main.sh"
SSHA="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no sa_101411256518727260534@$A"
SSHV="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no sa_101411256518727260534@$V"
PLOG=/home/alisachen_google_com/pd_disagg/results/runs/$RUN/prefill/server.log
DLOG=/home/alisachen_google_com/pd_disagg/results/runs/$RUN/decode/server.log
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
log() { echo "$(date -u '+%F %T') EDGE $*"; }
health() { echo "prefill=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:30000/health) decode=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$V:30000/health) lb=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$A:8080/health)"; }
exc() { echo "prefill_exc=$($SSHA "sudo grep -c 'Scheduler hit an exception\|Traceback' $PLOG" 2>/dev/null) decode_exc=$($SSHV "sudo grep -c 'Scheduler hit an exception\|Traceback' $DLOG" 2>/dev/null)"; }
flush_one() { for i in $(seq 1 ${2:-15}); do c=$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $1/flush_cache); [ "$c" = 200 ] && return 0; sleep 10; done; return 1; }
wipe() { flush_one http://$V:30000 && flush_one http://$A:30000; }
errs() { $PY - "$1" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
bad = [r for r in rows if r.get("error") not in (None, "None") or not r.get("completion_tokens")]
print(f"requests={len(rows)} failed={len(bad)}" + (f" first={str(bad[0].get('error') or 'no completion tokens')[:120]}" if bad else ""))
PY
}
static() { # label K -> runs the static workload, prints request/error counts
  $PY $SP/static_reuse.py --prefixes $2 --visits 3 --prefix 131072 --new 8192 --out-tokens 256 --concurrency 4 --seed 13 --run $RUN --label $1 --tokenizer $TOK --lb http://$A:8080 --prefill-url http://$A:30000 --decode-url http://$V:30000 --out $R/${RUN}_$1.jsonl > $R/${RUN}_$1.out 2>&1
  errs $R/${RUN}_$1.jsonl
}
recall() { # label sessions phase
  $PY $SP/victim_recall.py --sessions $2 --prefix 131072 --new 8192 --out-tokens 16 --concurrency 4 --seed 5 --run $RUN --phase $3 --label $1 --tokenizer $TOK --lb http://$A:8080 --out $R/${RUN}_$1.jsonl > $R/${RUN}_$1.out 2>&1
  errs $R/${RUN}_$1.jsonl
}

log "start: $(health) $(exc)"

log "E1 integrity: recalled outputs must equal a recompute after a flush; probes must match throughout"
wipe; timeout 3600 $PY $SP/victim_integrity.py --lb http://$A:8080 --flush http://$A:30000 http://$V:30000 --tokenizer $TOK --sessions 16 --prefix 131072 --new 8192 --out $R/${RUN}_integrity.json > $R/${RUN}_integrity.out 2>&1
log "E1 rc=$? $(grep -E '^SUMMARY' $R/${RUN}_integrity.out | cut -c1-700)"; log "E1 after: $(health) $(exc)"

log "E2 stress: concurrent recalls after a prefill-only flush, and client aborts mid-recall"
wipe; timeout 3600 $PY $SP/spill_stress.py --lb http://$A:8080 --prefill-url http://$A:30000 --decode-url http://$V:30000 --tokenizer $TOK --prefix 131072 --new 8192 --sessions 6 --phases concurrent,abort --flush-targets prefill --phase-timeout 900 --out $R/${RUN}_stress.json > $R/${RUN}_stress.out 2>&1
log "E2 rc=$? $(tail -3 $R/${RUN}_stress.out | tr '\n' ' ' | cut -c1-600)"; log "E2 after: $(health) $(exc)"

log "E3 flush under load: flush both engines 30 s into a static run"
wipe; (static e3_flush_load 8 > $R/${RUN}_e3.res) & bg=$!
sleep 30; fa=$(curl -s -m 60 -o /dev/null -w '%{http_code}' -X POST http://$A:30000/flush_cache); fv=$(curl -s -m 60 -o /dev/null -w '%{http_code}' -X POST http://$V:30000/flush_cache)
wait $bg; log "E3 flush codes prefill=$fa decode=$fv; $(cat $R/${RUN}_e3.res); $(health) $(exc)"

log "E4 decode killed while recalls are in flight, then restarted"
wipe; log "E4 fill: $(recall e4_fill 12 fill)"
(recall e4_recall 12 recall > $R/${RUN}_e4.res) & bg=$!
sleep 20; $PM stop-decode > /dev/null 2>&1; log "E4 decode stopped"
sleep 60; log "E4 during outage: $(health) $(exc)"
$PM start-decode $RECIPE $RUN > $R/${RUN}_e4_restart.log 2>&1; log "E4 decode restarted: $(tail -1 $R/${RUN}_e4_restart.log | cut -c1-100)"
( wait $bg ) 2>/dev/null; for i in $(seq 1 60); do kill -0 $bg 2>/dev/null || break; sleep 10; done; kill $bg 2>/dev/null
log "E4 recall during the kill: $(cat $R/${RUN}_e4.res 2>/dev/null)"
log "E4 after restart, static K=4: $(static e4_after 4); $(health) $(exc)"

log "E5 prefill killed while pushes are in flight, then restarted"
wipe; (recall e5_fill 16 fill > $R/${RUN}_e5.res) & bg=$!
sleep 45; $PM stop-prefill > /dev/null 2>&1; log "E5 prefill stopped"
sleep 30; kill $bg 2>/dev/null; log "E5 during outage: decode=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://$V:30000/health) $(exc)"
flush_one http://$V:30000 30 && log "E5 decode flush ok (landings of the dead prefill were released)" || log "E5 decode flush REFUSED for 5 min"
$PM start-prefill $RECIPE $RUN > $R/${RUN}_e5_restart.log 2>&1; log "E5 prefill restarted: $(tail -1 $R/${RUN}_e5_restart.log | cut -c1-100)"
log "E5 after restart, static K=4: $(static e5_after 4); $(health) $(exc)"
log "done: $(health) $(exc)"
