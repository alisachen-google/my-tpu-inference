#!/usr/bin/env python3
"""Tables (markdown) of offload off vs on from the points.jsonl of collected jobs."""
import json, sys
O = "/mnt/disks/scratch/alisachen/cloud-devkit-data/job-outputs/"
SP = "/tmp/claude-731364623/-home-alisachen-google-com/56a82281-be80-48e3-ae72-bffe0e08182f/scratchpad/"
def pts(path):
    last = {}
    for l in open(path):
        if l.startswith("{"):
            r = json.loads(l); last[r["label"]] = r
    return last
def job(j): return pts(O + j + "/pd1992/bench/points.jsonl")
def cell(r, k, nd=1, scale=1.0):
    return None if r is None or r.get(k) is None else scale * r[k]
def row(name, a, b, skip_tok=False):
    ha, hb = cell(a, "prefill_hit", scale=100), cell(b, "prefill_hit", scale=100)
    ta, tb = cell(a, "ttft_p50"), cell(b, "ttft_p50")
    ea, eb = cell(a, "e2e_p50"), cell(b, "e2e_p50")
    sa, sb = cell(a, "total_tok_s"), cell(b, "total_tok_s")
    if skip_tok: sb = None
    f = lambda x, s: "n/a" if x is None else s % x
    hit = f"{f(ha,'%.1f%%')} → {f(hb,'%.1f%%')}"; hg = "n/a" if None in (ha, hb) else f"{hb-ha:+.1f} pts"
    tt = f"{f(ta,'%.1f s')} → {f(tb,'%.1f s')}"; tg = "n/a" if None in (ta, tb) or not tb else f"{ta/tb:.2f}x"
    ee = f"{f(ea,'%.1f s')} → {f(eb,'%.1f s')}"; eg = "n/a" if None in (ea, eb) or not eb else f"{ea/eb:.2f}x"
    ss = f"{'n/a' if sa is None else format(sa, ',.0f')} → {'n/a' if sb is None else format(sb, ',.0f')}"
    sg = "n/a" if None in (sa, sb) or not sa else f"{100*(sb/sa-1):+.0f}%"
    return f"| {name} | {hit} | {hg} | {tt} | {tg} | {ee} | {eg} | {ss} | {sg} |"
HDR = "| Case | Prefill-side hit off → on | Hit gain | TTFT p50 off → on | TTFT speedup | E2E p50 off → on | E2E speedup | Total tok/s off → on | Throughput gain |\n|---|---|---|---|---|---|---|---|---|"
def table(rows): print(HDR); [print(r) for r in rows]; print()
which = sys.argv[1]
if which == "gpt_static":
    a, b = job("j-ade6c98d-55f1-4225-83a0"), job("j-3b4f7b55-8424-4b2b-b7ae")
    table([row(f"128k+8k, {k} docs", a[f"static_{k}"], b[f"static_{k}"]) for k in (4, 8, 12, 16, 20, 24, 28)] +
          [row(f"256k+16k, {k} docs", a[f"static256_{k}"], b[f"static256_{k}"]) for k in (2, 4, 6, 8, 10, 12, 14)])
elif which == "gpt_recall":
    a, b = pts(SP + "wb_off/points.jsonl"), job("j-fc37a8f9-6529-44d2-b15d")
    table([row(f"{k} sessions", a[f"recall_{k}_ret"], b[f"recall_{k}_ret"]) for k in (8, 12, 16)])
elif which in ("gpt_shared", "gpt_shared_2052", "qwen_shared"):
    a, b = {"gpt_shared": ("j-c42230ac-adfe-4eb3-9172", "j-a9e5fd90-6cb2-430c-a5b7"), "gpt_shared_2052": ("j-c42230ac-adfe-4eb3-9172", "j-e49f6c9a-df73-43cd-ac72"),
            "qwen_shared": ("j-b956931a-b498-4899-bbed", "j-dd4fe7c9-de61-4f6b-8294")}[which]
    a, b = job(a), job(b)
    names = {"shared16": "16 sessions, shared 8k prefix, 1 at a time", "shared16b": "16 sessions, shared prefix, 2 concurrent", "shared20": "20 sessions, shared prefix, 4 concurrent",
             "shared24": "24 sessions, shared prefix, 4 concurrent", "indep16": "16 independent sessions, 1 at a time"}
    table([row(n, a[k + "_ret"], b[k + "_ret"]) for k, n in names.items()])
elif which == "qwen_pp":
    a, b = job("j-98ae993a-ee51-42a7-b3db"), job("j-b7ab1318-89f2-4022-93e4")
    table([row(f"Recall, {k} sessions", a[f"recall_{k}_ret"], b[f"recall_{k}_ret"]) for k in (8, 12, 16)] +
          [row(f"Static, {k} docs", a[f"static_{k}"], b[f"static_{k}"], skip_tok=(k == 12)) for k in (4, 8, 12, 16)])
