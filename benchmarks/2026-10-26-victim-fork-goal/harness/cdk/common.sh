# Shared helpers for the CDK stage scripts. Expects: PY, HARNESS, PROMPTS, TOK, OUT, RUN, SHARED,
# PREFILL_URLS (space list), DECODE_URLS (space list), LB (random mini-lb url), lb_pin P D -> url of the pinned mini-lb.
NP=$(wc -w <<< "$PREFILL_URLS"); ND=$(wc -w <<< "$DECODE_URLS")
# A retried attempt (spot preemption) shares $OUT with the one before it: start every stage from clean result files
# for this RUN (I13), keeping the previous attempt's records aside.
fresh_run() { local prev="$OUT/attempt_$(date -u +%H%M%S)"; local f n=0; for f in "$OUT"/${RUN}_*; do [ -e "$f" ] || continue; mkdir -p "$prev"; mv "$f" "$prev/"; n=$((n+1)); done; [ $n -gt 0 ] && echo "moved $n result files of a previous attempt to $prev"; return 0; }
log() { echo "$(date -u '+%F %T') $*" | tee -a "$OUT/stage.log"; }
hc() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$1"; }
health() { local s=""; local i=0; for u in $PREFILL_URLS; do s="$s p$i=$(hc $u/health)"; i=$((i+1)); done; i=0; for u in $DECODE_URLS; do s="$s d$i=$(hc $u/health)"; i=$((i+1)); done; echo "$s lb=$(hc $LB/health)"; }
flush_one() { local i; for i in $(seq 1 ${2:-30}); do [ "$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $1/flush_cache)" = 200 ] && return 0; sleep 10; done; return 1; }
wipe() { local u; for u in $DECODE_URLS $PREFILL_URLS; do flush_one $u || { log "WIPE FAILED on $u"; return 1; }; done; }
# Prefill-side hit from /metrics deltas over a case: snapshot before/after, sum over every prefill.
snap() { local u; for u in $PREFILL_URLS; do curl -s -m 10 "$u/metrics" | awk '/^sglang:(prompt|cached)_tokens_total/ {k=$1; sub(/\{.*/,"",k); s[k]+=$2} END {for (k in s) printf "%s %s\n", k, s[k]}'; done | awk '{s[$1]+=$2} END {for (k in s) printf "%s %s\n", k, s[k]}' > "$1"; }
hit_from_snaps() { python3 - "$1" "$2" <<'PY'
import sys
def load(p):
    d = {}
    for l in open(p):
        k, v = l.split(); d[k] = float(v)
    return d
a, b = load(sys.argv[1]), load(sys.argv[2])
c = b.get("sglang:cached_tokens_total", 0) - a.get("sglang:cached_tokens_total", 0)
p = b.get("sglang:prompt_tokens_total", 0) - a.get("sglang:prompt_tokens_total", 0)
print(f"prefill-side hit {100*c/p if p else 0:.1f}% (cached {c:.0f} of {p:.0f} prompt tokens)")
PY
}
strict() { $PY $HARNESS/strict.py "$@"; }
hits() { python3 - "$OUT/${RUN}_$1.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.startswith('{')]
rec = [r for r in rows if r.get('phase') == 'recall' and r.get('reusable_tokens')]
ok = [r for r in rec if not r.get('error') and r.get('completion_tokens')]
if rec:
    ttft = sorted(r['ttft_s'] for r in ok if r.get('ttft_s') is not None)
    p = lambda xs, q: xs[min(len(xs)-1, int(q*len(xs)))] if xs else float('nan')
    print(f"client-side hit {100*sum(r.get('cached_tokens') or 0 for r in rec)/sum(r['reusable_tokens'] for r in rec):.1f}% over {len(rec)} requests; ttft p50 {p(ttft,.5):.1f}s p95 {p(ttft,.95):.1f}s")
PY
}
# recall LABEL SESSIONS PHASE LB [SEED] [PREFIX] [NEW] [CONCURRENCY]: the recall workload through one mini-lb; prints strict + hit.
recall() { local label=$1 n=$2 phase=$3 lb=$4 seed=${5:-5} prefix=${6:-131072} new=${7:-8192} conc=${8:-4}
  snap "$OUT/${RUN}_$label.m0"
  $PY $HARNESS/victim_recall.py --sessions $n --prefix $prefix --new $new --out-tokens 16 --concurrency $conc --seed $seed --run $RUN --phase $phase --settle ${SETTLE:-20} --label $label --tokenizer $TOK --prompts $PROMPTS --lb $lb --out $OUT/${RUN}_$label.jsonl > $OUT/${RUN}_$label.out 2>&1
  snap "$OUT/${RUN}_$label.m1"
  echo "$(strict $OUT/${RUN}_$label.jsonl); $(hit_from_snaps $OUT/${RUN}_$label.m0 $OUT/${RUN}_$label.m1); $(hits $label)"; }
# static LABEL DOCS LB PREFILL_URL DECODE_URL
static() { local label=$1 k=$2 lb=$3 pu=$4 du=$5
  snap "$OUT/${RUN}_$label.m0"
  $PY $HARNESS/static_reuse.py --prefixes $k --visits 3 --prefix 131072 --new 8192 --out-tokens 256 --concurrency 4 --seed 13 --run $RUN --label $label --tokenizer $TOK --prompts $PROMPTS --lb $lb --prefill-url $pu --decode-url $du --out $OUT/${RUN}_$label.jsonl > $OUT/${RUN}_$label.out 2>&1
  snap "$OUT/${RUN}_$label.m1"
  echo "$(strict $OUT/${RUN}_$label.jsonl); $(hit_from_snaps $OUT/${RUN}_$label.m0 $OUT/${RUN}_$label.m1)"; }
# keepalive LB: 24 short sessions (32k+4k, concurrency 8) through LB, so the prefill keeps serving while under host
# pressure and pushes the cold branches it just filled (the X2b procedure of goal_2p1d_x2b.sh).
keepalive() { echo "$(recall ${2:-keepalive} 24 fill $1 62 32768 4096 8)"; }
# Engine health from the server log copies the server pods refresh under $SHARED/<role>-<i>/server.log.
exc() { local s="" f; for f in $SHARED/prefill-*/server.log $SHARED/decode-*/server.log; do [ -f "$f" ] || continue; s="$s $(basename $(dirname $f))=$(grep -c 'Scheduler hit an exception\|out of memory' $f 2>/dev/null)"; done; echo "exceptions:$s"; }
evidence() { local f; for f in $SHARED/prefill-*/server.log; do [ -f "$f" ] || continue; echo "== $(basename $(dirname $f))"
    grep -h '\[victim-push\] role=prefill' $f | grep 'TP0 ' | tail -1 | cut -c1-220
    echo "recall commits (TP0): $(grep -h '\[prefix-pull\] room=' $f | grep -c 'TP0 ')  ranks pushing: $(grep -h '\[victim-push\] role=prefill.*stored=' $f | grep -o 'TP[0-9]' | sort -u | tr '\n' ' ')"
    echo "warnings: $(grep -ch 'Cannot register host read\|Cannot start host read\|did not settle\|Cannot poll host read\|failed (errno' $f)  errors: $(grep -ch 'Traceback\|Scheduler hit an exception\|RuntimeError\|AssertionError\|KeyError' $f)"; done
  for f in $SHARED/decode-*/server.log; do [ -f "$f" ] || continue; echo "== $(basename $(dirname $f))"
    grep -h '\[victim-push\] role=decode' $f | grep 'TP0 ' | tail -1 | cut -c1-240
    echo "ranks landing: $(grep -h '\[victim-push\] role=decode.*landed=' $f | grep -o 'TP[0-9]' | sort -u | tr '\n' ' ')  refused pulls: $(grep -ch 'cannot be served, refusing' $f)  errors: $(grep -ch 'Traceback\|Scheduler hit an exception\|RuntimeError\|AssertionError\|KeyError' $f)"; done
  echo "== B3 rank consistency"; python3 $HARNESS/rank_consistency.py $SHARED/prefill-*/server.log $SHARED/decode-*/server.log 2>&1; }
