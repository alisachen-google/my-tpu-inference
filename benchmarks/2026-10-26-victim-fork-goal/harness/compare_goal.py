#!/usr/bin/env python3
"""Before vs after markdown tables from the goal runs (logs/goal_before_1.log, logs/goal_after_1.log).

Prefill hit = prefill /metrics delta over the measured phase (cross-checked against the prefill
log's per-batch #cached-token sum). Latency/throughput from the client summaries.
"""
import json
import re
import sys
from pathlib import Path

L = Path.home() / "pd_disagg/spill/logs"


def load(name):
    out = {}
    p = L / f"goal_{name}_1.log"
    if p.exists():
        for line in p.open():
            if line.startswith("POINT "):
                r = json.loads(line[6:])
                out[r["label"]] = r
    return out


def f(x, fmt):
    return "-" if x is None else fmt.format(x)


def pair(x, y, fmt):
    return f"{f(x, fmt)} → {f(y, fmt)}"


def ratio(x, y):
    return "-" if not x or not y else f"{x / y:.2f}x"


def victim(r):
    v = (r or {}).get("victim", "")
    pushed = re.search(r"pushed=(\d+)", v)
    stored = re.search(r"stored=(\d+)", v)
    pulls = re.search(r"prefix-pull commits \(TP0\): (\d+)", v)
    toks = re.search(r"prefix-pull tokens \(TP0\): (\d+)", v)
    if not (pushed or pulls):
        return "-"
    return f"push {pushed[1] if pushed else '?'}/stored {stored[1] if stored else '?'}, pulls {pulls[1] if pulls else '?'} ({int(toks[1]) / 1e6:.2f}M tok)" if toks else f"pulls {pulls[1] if pulls else '?'}"


def main():
    b, a = load("before"), load("after")
    labs = sorted(set(b) | set(a), key=lambda l: (l.split("_")[0], int(l.split("_p")[1].split("k")[0]), int(l.rsplit("_", 1)[1][1:])))
    for kind, title, unit in (("recall", "Recall workload (fill N sessions, recall oldest first; recall phase)", "Sessions"),
                              ("static", "Static prefix-reuse workload (K documents x 3 visits, shuffled)", "Docs")):
        print(f"### {title}\n")
        print(f"| Prefix+new | {unit} | Prefill hit before → after | TTFT p50 before → after | TTFT speedup | E2E p50 before → after | Total tok/s before → after | Throughput gain | Victim push / pull (after) |")
        print("|---|---|---|---|---|---|---|---|---|")
        for lab in labs:
            if not lab.startswith(kind):
                continue
            x, y = b.get(lab), a.get(lab)
            m = re.match(r"\w+_p(\d+)k_n(\d+)k_[sk](\d+)", lab)
            gx, gy = (x or {}), (y or {})
            print(f"| {m[1]}k+{m[2]}k | {m[3]} | {pair(gx.get('prefill_hit'), gy.get('prefill_hit'), '{:.1%}')} | "
                  f"{pair(gx.get('ttft50'), gy.get('ttft50'), '{:.1f} s')} | {ratio(gx.get('ttft50'), gy.get('ttft50'))} | "
                  f"{pair(gx.get('e2e50'), gy.get('e2e50'), '{:.1f} s')} | {pair(gx.get('tok_s'), gy.get('tok_s'), '{:,.0f}')} | "
                  f"{ratio(gy.get('tok_s'), gx.get('tok_s'))} | {victim(y)} |")
        print()
    # cumulative victim counters are per run; note it
    print(f"_Before points: {len(b)}; after points: {len(a)}. Victim counters are cumulative within the after run._")


if __name__ == "__main__":
    main()
