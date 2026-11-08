#!/usr/bin/env python3
"""Switch on vs off per layout and case: recall-phase prefix hit, TTFT and e2e percentiles from the clients' records.
compare_layouts.py <results dir> <layout> ...   (layout = 1p2d | 2p1d | 2p2d; reads g1992b_<layout>_1_<case>.jsonl and g1992b_<layout>_off_1_<case>.jsonl)"""
import glob, json, os, statistics, sys

CASES = {
    "1p2d": [("w2_d1", "sticky: 8 sessions pinned to decode 1"), ("w2_d2", "sticky: 8 sessions pinned to decode 2"), ("w1_recall", "random decode: 16 sessions")],
    "2p1d": [("x2_recall_b", "cross-prefill: filled via prefill a, returned via prefill b"), ("x2_recall_a", "returned via prefill a again"), ("x1_recall", "random prefill: 16 sessions")],
    "2p2d": [("y2_b_v7", "other prefill, same decode"), ("y2_a_g", "same prefill, other decode"), ("y2_b_g", "other prefill, other decode"), ("y1_recall", "random prefill and decode: 16 sessions")],
}

def newest(pattern):
    files = glob.glob(pattern)
    return max(files, key=os.path.getmtime) if files else None

def stats(path):
    path = newest(path)
    if path is None:
        return None
    rows = [json.loads(l) for l in open(path) if l.startswith("{")]
    rec = [r for r in rows if r.get("phase") == "recall" and r.get("reusable_tokens")]
    if not rec:
        rec = [r for r in rows if r.get("phase") == "recall"]
    if not rec:
        return None
    ok = [r for r in rec if not r.get("error") and r.get("completion_tokens")]
    hit = 100 * sum(r.get("cached_tokens") or 0 for r in ok) / max(1, sum(r.get("reusable_tokens") or r.get("prompt_tokens") for r in ok))
    ttft = sorted(r["ttft_s"] for r in ok if r.get("ttft_s") is not None)
    e2e = sorted(r["e2e_s"] for r in ok if r.get("e2e_s") is not None)
    p = lambda xs, q: xs[min(len(xs) - 1, int(q * len(xs)))] if xs else float("nan")
    return dict(n=len(rec), failed=len(rec) - len(ok), hit=hit, ttft50=p(ttft, 0.5), ttft95=p(ttft, 0.95), e2e50=p(e2e, 0.5))

def main():
    rdir, layouts = sys.argv[1], sys.argv[2:]
    print("| Layout | Case | Requests (on / off) | Prefix hit on -> off | TTFT p50 on -> off | TTFT p95 on -> off | E2E p50 on -> off |")
    print("|---|---|---|---|---|---|---|")
    for lay in layouts:
        for case, label in CASES[lay]:
            on = stats(f"{rdir}/g1992b_{lay}_[0-9]_{case}.jsonl"); off = stats(f"{rdir}/g1992b_{lay}_off_[0-9]_{case}.jsonl")
            f = lambda s, k, fmt: (fmt % s[k]) if s else "-"
            print(f"| {lay.upper()} | {label} | {f(on,'n','%d')} / {f(off,'n','%d')} (failed {f(on,'failed','%d')} / {f(off,'failed','%d')}) | {f(on,'hit','%.1f%%')} -> {f(off,'hit','%.1f%%')} | {f(on,'ttft50','%.1f s')} -> {f(off,'ttft50','%.1f s')} | {f(on,'ttft95','%.1f s')} -> {f(off,'ttft95','%.1f s')} | {f(on,'e2e50','%.1f s')} -> {f(off,'e2e50','%.1f s')} |")

if __name__ == "__main__":
    main()
