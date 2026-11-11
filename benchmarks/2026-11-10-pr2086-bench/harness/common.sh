# Shared helpers for the CDK stage scripts. Expects: PY, HARNESS, PROMPTS, TOK, OUT, RUN, SHARED,
# PREFILL_URLS (space list), DECODE_URLS (space list), LB (random mini-lb url), lb_pin P D -> url of the pinned mini-lb.
NP=$(wc -w <<< "$PREFILL_URLS"); ND=$(wc -w <<< "$DECODE_URLS")
# A retried attempt (spot preemption) shares $OUT with the one before it: start every stage from clean result files
# for this RUN (I13), keeping the previous attempt's records aside.
fresh_run() { local prev="$OUT/attempt_$(date -u +%H%M%S)"; local f n=0; for f in "$OUT"/${RUN}_* "$OUT"/points.jsonl; do [ -e "$f" ] || continue; mkdir -p "$prev"; mv "$f" "$prev/"; n=$((n+1)); done; [ $n -gt 0 ] && echo "moved $n result files of a previous attempt to $prev"; return 0; }
log() { echo "$(date -u '+%F %T') $*" | tee -a "$OUT/stage.log"; }
now() { date -u '+%F %T'; }
hc() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$1"; }
health() { local s=""; local i=0; for u in $PREFILL_URLS; do s="$s p$i=$(hc $u/health)"; i=$((i+1)); done; i=0; for u in $DECODE_URLS; do s="$s d$i=$(hc $u/health)"; i=$((i+1)); done; echo "$s lb=$(hc $LB/health)"; }
flush_one() { local i; for i in $(seq 1 ${2:-30}); do [ "$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $1/flush_cache)" = 200 ] && return 0; sleep 10; done; return 1; }
wipe() { local u; for u in $DECODE_URLS $PREFILL_URLS; do flush_one $u || { log "WIPE FAILED on $u"; return 1; }; done; }
# Per-engine snapshot of the request/token counters: lines "<role>-<i> <metric> <value>" for every prefill and decode.
# point_metrics.py takes the prefill-side hit (cached / prompt tokens over every prefill) and the per-engine request
# deltas (which pair served a sticky case) from two of these.
snap() { local u i=0; : > "$1"
  for u in $PREFILL_URLS; do curl -s -m 10 "$u/metrics" | awk -v e="prefill-$i" '/^sglang:(prompt|cached|generation)_tokens_total|^sglang:num_requests_total/ {k=$1; sub(/\{.*/,"",k); s[k]+=$2} END {for (k in s) printf "%s %s %s\n", e, k, s[k]}' >> "$1"; i=$((i+1)); done; i=0
  for u in $DECODE_URLS; do curl -s -m 10 "$u/metrics" | awk -v e="decode-$i" '/^sglang:(prompt|cached|generation)_tokens_total|^sglang:num_requests_total/ {k=$1; sub(/\{.*/,"",k); s[k]+=$2} END {for (k in s) printf "%s %s %s\n", e, k, s[k]}' >> "$1"; i=$((i+1)); done; }
hit_from_snaps() { python3 - "$1" "$2" <<'PY'
import sys
def load(p):
    d = {}
    for l in open(p):
        f = l.split()
        if len(f) == 3 and f[0].startswith("prefill"): d[f[1]] = d.get(f[1], 0) + float(f[2])
        elif len(f) == 2: d[f[0]] = d.get(f[0], 0) + float(f[1])
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
c = b.get("sglang:cached_tokens_total", 0) - a.get("sglang:cached_tokens_total", 0)
p = b.get("sglang:prompt_tokens_total", 0) - a.get("sglang:prompt_tokens_total", 0)
print(f"prefill-side hit {100*c/p if p else 0:.1f}% (cached {c:.0f} of {p:.0f} prompt tokens)")
PY
}
strict() { $PY $HARNESS/strict.py "$@"; }
# point LABEL PHASE EXPECT T0 T1 [KIND]: one POINT line (throughput, hit, latency, route) for the case LABEL from its
# jsonl + snaps; appended to $OUT/points.jsonl. EXPECT is the pair that should have served it (p0d0, any).
point() { python3 $HARNESS/point_metrics.py --run $RUN --label $1 --phase $2 --expect $3 --t0 "$4" --t1 "$5" --kind ${6:-recall} \
  --jsonl $OUT/${RUN}_$1.jsonl --m0 $OUT/${RUN}_$1.m0 --m1 $OUT/${RUN}_$1.m1 --out $OUT/points.jsonl; }
# recall LABEL SESSIONS PHASE LB [SEED] [PREFIX] [NEW] [CONCURRENCY] [EXPECT]: the recall workload through one
# mini-lb, one phase (fill or recall) per call so the snaps bracket exactly that phase; prints strict + POINT.
recall() { local label=$1 n=$2 phase=$3 lb=$4 seed=${5:-5} prefix=${6:-131072} new=${7:-8192} conc=${8:-4} expect=${9:-any} t0 t1
  snap "$OUT/${RUN}_$label.m0"; t0=$(now)
  $PY $HARNESS/victim_recall.py --sessions $n --prefix $prefix --new $new --out-tokens ${OUT_TOKENS:-16} --concurrency $conc --seed $seed --run $RUN --phase $phase --settle ${SETTLE:-20} --label $label --tokenizer $TOK --prompts $PROMPTS --lb $lb --out $OUT/${RUN}_$label.jsonl > $OUT/${RUN}_$label.out 2>&1
  t1=$(now); snap "$OUT/${RUN}_$label.m1"
  echo "$(strict $OUT/${RUN}_$label.jsonl); $(point $label $phase $expect "$t0" "$t1" recall)"; }
# static LABEL DOCS LB PREFILL_URL DECODE_URL [EXPECT]
static() { local label=$1 k=$2 lb=$3 pu=$4 du=$5 expect=${6:-any} t0 t1
  snap "$OUT/${RUN}_$label.m0"; t0=$(now)
  $PY $HARNESS/static_reuse.py --prefixes $k --visits 3 --prefix 131072 --new 8192 --out-tokens 256 --concurrency 4 --seed 13 --run $RUN --label $label --tokenizer $TOK --prompts $PROMPTS --lb $lb --prefill-url $pu --decode-url $du --out $OUT/${RUN}_$label.jsonl > $OUT/${RUN}_$label.out 2>&1
  t1=$(now); snap "$OUT/${RUN}_$label.m1"
  echo "$(strict $OUT/${RUN}_$label.jsonl); $(point $label all $expect "$t0" "$t1" static)"; }
# keepalive LB [LABEL]: 24 short sessions (32k+4k, concurrency 8) through LB, so the prefill keeps serving while
# under host pressure and write-back evicts and pushes the cold branches it just filled (goal_2p1d_x2b.sh).
keepalive() { echo "$(recall ${2:-keepalive} 24 fill $1 62 32768 4096 8)"; }
# Engine health from the server log copies the server pods refresh under $SHARED/<role>-<i>/server.log: the five
# invalidating patterns of the brief, per engine.
EXC_PAT='Scheduler hit an exception|out of memory|malformed|DEADLINE_EXCEEDED|subtree drop declined'
exc() { local s="" f; for f in $SHARED/prefill-*/server.log $SHARED/decode-*/server.log; do [ -f "$f" ] || continue; s="$s $(basename $(dirname $f))=$(grep -c -E "$EXC_PAT" $f 2>/dev/null)"; done; echo "exceptions:$s"; }
exc_total() { local f n=0; for f in $SHARED/prefill-*/server.log $SHARED/decode-*/server.log; do [ -f "$f" ] || continue; n=$((n + $(grep -c -E "$EXC_PAT" $f 2>/dev/null))); done; echo $n; }
# Offload counters ([dram-offload] push / landing / recall lines of PR 2086) and rank consistency from the log copies.
evidence() { python3 $HARNESS/offload_counters.py --points $OUT/points.jsonl $SHARED/prefill-*/server.log $SHARED/decode-*/server.log 2>&1; }
