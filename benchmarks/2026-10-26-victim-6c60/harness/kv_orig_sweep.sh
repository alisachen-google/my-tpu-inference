#!/usr/bin/env bash
# Original victim-cache benchmark client (exp/1021 kv_client.py, unchanged) against the running pair.
# Workload = victim_sweep.sh COMMON: KV_CHAIN=1 KV_PREFIX_TOKENS=4096 KV_TURNS=4 KV_ROUNDS=2 KV_CONC=8
# KV_OUT_TOKENS=128 KV_SEED=1 (suffix 64). Client runs on host a (as in the prefill pod).
#   RUN=<run> POINTS="..." kv_orig_sweep.sh
set -uo pipefail
ME=alisachen_google_com; A=10.128.15.217; B=10.128.0.90
SSH="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no sa_101411256518727260534@$A"
RUN=${RUN:?run}; POINTS=${POINTS:-"16 32 64 96 128 192 256 384 512 768 1024"}
OUT=$HOME/pd_disagg/spill/results_orig; mkdir -p $OUT
MODEL=/mnt/data/tt/hf-cache/hub/models--openai--gpt-oss-120b/snapshots/b5c939de8f754692c1647ca79fbf85e8c1e70f8a
log() { echo "$(date -u '+%F %T') $*"; }
flush() { # retry while a role refuses (victim transfers draining)
  for u in http://$A:30000 http://$B:30000; do
    for i in $(seq 1 30); do c=$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $u/flush_cache); [ "$c" = 200 ] && break; sleep 10; done
    [ "$c" = 200 ] || log "flush $u failed ($c)"
  done
}
for P in $POINTS; do
  curl -sf -m 10 http://$A:8080/health >/dev/null || { log "LB not healthy; stop"; exit 1; }
  flush; sleep 10
  log "$RUN point sessions=$P"
  D=/tmp/kvorig/$RUN/n$P
  $SSH "sudo -n -iu $ME bash -lc $(printf %q "mkdir -p $D && cd $D && env KV_CHAIN=1 KV_PREFIX_TOKENS=4096 KV_TURNS=4 KV_ROUNDS=2 KV_CONC=8 KV_OUT_TOKENS=128 KV_SEED=1 KV_NUM_PREFIXES=$P KV_URL=http://127.0.0.1:8080 KV_PREFILL_METRICS=http://127.0.0.1:30000/metrics KV_DECODE_METRICS=http://$B:30000/metrics KV_MODEL_PATH=$MODEL KV_MODEL_NAME=gpt-oss-120b KV_REQ_TIMEOUT=1800 KV_PREFILL_LOG=/home/$ME/pd_disagg/results/runs/$RUN/prefill/server.log KV_SUMMARY=$D/kv_summary.json KV_METRICS_DIR=$D KV_RUN=$RUN SGLANG_DISAGG_PREFILL_PULL_DECODE_PREFIX=\${SGLANG_DISAGG_PREFILL_PULL_DECODE_PREFIX:-} timeout 14400 /home/$ME/venv/sglang/bin/python /home/$ME/pd_disagg/spill/orig/kv_client.py > $D/kv_client.log 2>&1; echo rc=\$?")"
  $SSH "sudo cat $D/kv_summary.json" > $OUT/${RUN}_n$P.json 2>/dev/null
  $SSH "sudo cat $D/kv_client.log" > $OUT/${RUN}_n$P.client.log 2>/dev/null
  $SSH "sudo cat $D/kv_records.json" > $OUT/${RUN}_n$P.records.json 2>/dev/null
  python3 - "$OUT/${RUN}_n$P.json" <<'PY'
import json,sys
try: s=json.load(open(sys.argv[1]))
except Exception as e: print("  no summary", e); sys.exit()
pt=s["per_turn"]; warm=[x["lat_p50_s"] for x in pt if x["k"]>0 and x["lat_p50_s"] is not None]
print(f"  RESULT n={s['config']['num_prefixes']} ok={s['requests']['ok']}/{s['requests']['total']} prefill_cached={s['prefill']['cached_frac']} wall={s['workload_wall_s']} warm_p50~{sorted(warm)[len(warm)//2] if warm else None} per_turn_cached={[x['cached_frac'] for x in pt]}")
PY
  bash $HOME/pd_disagg/spill/victim_stats.sh $RUN | grep -E 'push|pull'
done
log "SWEEP DONE $RUN"
