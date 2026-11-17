#!/usr/bin/env python3
"""Markdown tables, offload off vs on, for the PR 2202 pipeline-parallel sweep (combo jobs: bench/shared + bench/ladders)."""
import json, os, sys
O = "/mnt/disks/scratch/alisachen/cloud-devkit-data/job-outputs/"
def pts(j):
    last = {}
    for sub in ("shared", "ladders", ""):
        p = O + j + "/pd1992/bench/" + sub + "/points.jsonl"
        if os.path.exists(p):
            for l in open(p):
                if l.startswith("{"):
                    r = json.loads(l); last[r["label"]] = r
    return last
def row(name, a, b):
    if not a.get("ttft_p50") or not b.get("ttft_p50"):
        return f"| {name} | not applicable (requests rejected: prompt over the model's context) | | | | | | | |"
    ha, hb = 100 * a["prefill_hit"], 100 * b["prefill_hit"]
    return (f"| {name} | {ha:.1f}% → {hb:.1f}% | {hb-ha:+.1f} pts | {a['ttft_p50']:.1f} s → {b['ttft_p50']:.1f} s | {a['ttft_p50']/b['ttft_p50']:.2f}x | "
            f"{a['e2e_p50']:.1f} s → {b['e2e_p50']:.1f} s | {a['e2e_p50']/b['e2e_p50']:.2f}x | {a['total_tok_s']:,.0f} → {b['total_tok_s']:,.0f} | {100*(b['total_tok_s']/a['total_tok_s']-1):+.0f}% |")
HDR = "| Case | Prefill-side hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |\n|---|---|---|---|---|---|---|---|---|"
off, on, mixoff, mixon, with256 = sys.argv[1:6]
a, b = pts(off), pts(on)
print("**Recall ladder (128k+8k sessions, return phase)**\n"); print(HDR)
for k in (8, 12, 16): print(row(f"{k} sessions", a[f"recall_{k}_ret"], b[f"recall_{k}_ret"]))
print("\n**Static prefix reuse**\n"); print(HDR)
for k in (4, 8, 12, 16, 20, 24, 28): print(row(f"128k+8k, {k} docs", a[f"static_{k}"], b[f"static_{k}"]))
if with256 == "1":
    for k in (2, 4, 6, 8, 10, 12, 14): print(row(f"256k+16k, {k} docs", a[f"static256_{k}"], b[f"static256_{k}"]))
print("\n**Sessions behind a shared 8k prefix, and independent sessions (return phase)**\n"); print(HDR)
for k, n in (("shared16", "16 sessions, shared prefix, 1 at a time"), ("shared16b", "16 sessions, shared prefix, 2 concurrent"), ("shared20", "20 sessions, shared prefix, 4 concurrent"), ("shared24", "24 sessions, shared prefix, 4 concurrent"), ("indep16", "16 independent sessions, 1 at a time")):
    print(row(n, a[k + "_ret"], b[k + "_ret"]))
ma, mb = pts(mixoff), pts(mixon)
print("\n**Mixed sizes (hit is over both streams together)**\n"); print(HDR)
print(row("Long 128k+8k, 8 docs x 3, concurrency 4", ma["mixed_long"], mb["mixed_long"]))
print(row("Short 32k+4k, 48 sessions, concurrency 8", ma["mixed_short"], mb["mixed_short"]))
