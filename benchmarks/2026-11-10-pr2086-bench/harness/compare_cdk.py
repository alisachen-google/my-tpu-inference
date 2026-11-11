#!/usr/bin/env python3
"""Switch on vs off per layout and case from the CDK bench outputs: prefill-side hit (prefill /metrics deltas, the
.m0/.m1 snapshots the stage wrote; the client-side cached_tokens is decode-inflated when the switch is off), request
and failure counts, TTFT p50/p95 and e2e p50 of the recall-phase requests.
compare_cdk.py <results dir> <layout> ...   (reads <prefix>_<layout>_<n>_<case>.jsonl and _off_; RUN_PREFIX, default g1992b)"""
import glob, json, os, sys
PREFIX = os.environ.get("RUN_PREFIX", "g1992b")
CASES = {
    "1p1d": [("z2_recall", "sticky: 12 sessions on the pair"), ("z1_recall", "16 sessions via the lb")],
    "1p2d": [("w2_d1", "sticky: 8 sessions pinned to decode 0"), ("w2_d2", "sticky: 8 sessions pinned to decode 1"), ("w1_recall", "random decode: 16 sessions")],
    "2p1d": [("x2_recall_b", "cross-prefill: filled via prefill 0, returned via prefill 1"), ("x2_recall_a", "returned via prefill 0 again"), ("x1_recall", "random prefill: 16 sessions")],
    "2p2d": [("y2_b_v7", "other prefill, same decode"), ("y2_a_g", "same prefill, other decode"), ("y2_b_g", "other prefill, other decode"), ("y1_recall", "random prefill and decode: 16 sessions")],
}

def newest(pattern):
    files = glob.glob(pattern)
    return max(files, key=os.path.getmtime) if files else None

def metrics(path):
    d = {}
    if path and os.path.exists(path):
        for l in open(path):
            k, v = l.split(); d[k] = float(v)
    return d

def stats(base):
    path = newest(base + ".jsonl")
    if path is None:
        return None
    rows = [json.loads(l) for l in open(path) if l.startswith("{")]
    rec = [r for r in rows if r.get("phase") == "recall"] or rows
    ok = [r for r in rec if not r.get("error") and r.get("completion_tokens")]
    m0, m1 = metrics(path[:-6] + ".m0"), metrics(path[:-6] + ".m1")
    c = m1.get("sglang:cached_tokens_total", 0) - m0.get("sglang:cached_tokens_total", 0)
    p = m1.get("sglang:prompt_tokens_total", 0) - m0.get("sglang:prompt_tokens_total", 0)
    q = lambda xs, f: (sorted(xs)[min(len(xs) - 1, int(f * len(xs)))] if xs else float("nan"))
    ttft = [r["ttft_s"] for r in ok if r.get("ttft_s") is not None]; e2e = [r["e2e_s"] for r in ok if r.get("e2e_s") is not None]
    return {"n": len(rows), "failed": len(rows) - len([r for r in rows if not r.get("error") and r.get("completion_tokens")]),
            "hit": 100 * c / p if p else float("nan"), "ttft50": q(ttft, .5), "ttft95": q(ttft, .95), "e2e50": q(e2e, .5)}

rdir = sys.argv[1]
print("| Layout | Case | Requests on / off (failed) | Prefill-side hit on -> off | TTFT p50 on -> off | TTFT p95 on -> off | E2E p50 on -> off |")
print("|---|---|---|---|---|---|---|")
for lay in sys.argv[2:]:
    for case, desc in CASES[lay]:
        on = stats(f"{rdir}/{PREFIX}_{lay}_[0-9]_{case}"); off = stats(f"{rdir}/{PREFIX}_{lay}_off_[0-9]_{case}")
        f = lambda s, k, fmt: (fmt % s[k]) if s else "-"
        print(f"| {lay.upper()} | {desc} | {f(on,'n','%d')} / {f(off,'n','%d')} ({f(on,'failed','%d')} / {f(off,'failed','%d')}) | "
              f"{f(on,'hit','%.1f%%')} -> {f(off,'hit','%.1f%%')} | {f(on,'ttft50','%.1f s')} -> {f(off,'ttft50','%.1f s')} | "
              f"{f(on,'ttft95','%.1f s')} -> {f(off,'ttft95','%.1f s')} | {f(on,'e2e50','%.1f s')} -> {f(off,'e2e50','%.1f s')} |")
