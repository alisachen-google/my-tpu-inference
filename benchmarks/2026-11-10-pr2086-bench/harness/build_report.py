#!/usr/bin/env python3
"""Markdown campaign table (off -> on) from two job output directories of the same stage.

build_report.py --on <job-output>/pd1992 --off <job-output>/pd1992 [--grace 45]
Each directory holds bench/points.jsonl (point_metrics.py lines), bench/stage.log and <role>-<i>/server.log. Prints:
the point table (requests on/off, prefill hit, total and output tok/s, requests/min, TTFT p50/p95, ITL p50, and the on
arm's per-point offload counter deltas), the integrity SUMMARY lines of both arms, and the final counters of each engine.
"""
import argparse, glob, json, os, re, sys
from datetime import datetime, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import offload_counters as oc  # noqa: E402


def load_points(d):
    pts = {}
    p = os.path.join(d, "bench", "points.jsonl")
    if os.path.exists(p):
        for l in open(p):
            if l.startswith("{"):
                r = json.loads(l); pts[(r["label"], r.get("phase", "all"))] = r
    return pts


def engines(d):
    out = {}
    for path in sorted(glob.glob(os.path.join(d, "*-*", "server.log"))):
        name = os.path.basename(os.path.dirname(path))
        if name.startswith(("prefill", "decode")):
            out[name] = oc.parse(path)
    return out


def deltas(eng, t0, t1, grace):
    if not t0 or not t1:
        return {}
    t0 = datetime.strptime(t0, "%Y-%m-%d %H:%M:%S"); t1 = datetime.strptime(t1, "%Y-%m-%d %H:%M:%S") + timedelta(seconds=grace)
    agg = {}
    for name, (series, *_rest) in eng.items():
        for w in ("push", "landing", "recall"):
            if (w, 0) in series:
                v0, v1 = oc.value_at(series[(w, 0)], t0), oc.value_at(series[(w, 0)], t1)
                for k in oc.KEYS[w]:
                    dv = v1.get(k, 0) - v0.get(k, 0)
                    if dv:
                        agg[f"{w}.{k}"] = agg.get(f"{w}.{k}", 0) + dv
    return agg


def fmt_counters(a):
    if not a:
        return "none"
    parts = []
    if a.get("push.started") or a.get("push.stored"): parts.append(f"push {a.get('push.stored', 0)}/{a.get('push.started', 0)} stored")
    if a.get("landing.received"): parts.append(f"land {a.get('landing.landed', 0)}/{a.get('landing.received', 0)}" + (f" fail {a['landing.failed']}" if a.get("landing.failed") else "") + (f" no_room {a['landing.no_room']}" if a.get("landing.no_room") else ""))
    if a.get("recall.offers") or a.get("recall.pulls"): parts.append(f"recall {a.get('recall.pulls', 0)}/{a.get('recall.offers', 0)} ({a.get('recall.pulled_tokens', 0)/1e6:.2f}M tok" + (f", {a.get('recall.pulled_swa_tokens', 0)} swa" if a.get("recall.pulled_swa_tokens") else "") + ")" + (f" fail {a['recall.failed']}" if a.get("recall.failed") else ""))
    return "; ".join(parts) or "none"


def f(x, nd=1, suf=""):
    return "-" if x is None else f"{x:.{nd}f}{suf}"


def pc(x):
    return "-" if x is None else f"{100*x:.1f}%"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--on", required=True); ap.add_argument("--off", required=True); ap.add_argument("--grace", type=float, default=45.0)
    a = ap.parse_args()
    on, off = load_points(a.on), load_points(a.off)
    eon = engines(a.on)
    print("| Point | Requests on / off (errors) | Prefill hit off -> on | Total tok/s off -> on | Output tok/s off -> on | Req/min off -> on | TTFT p50 / p95 off -> on | ITL p50 off -> on | Offload counters (on arm, this point) |")
    print("|---|---|---|---|---|---|---|---|---|")
    for key, r in on.items():
        o = off.get(key)
        if o is None:
            o = {}
        lab = f"{key[0]}" + ("" if key[1] in ("all", None) else f" ({key[1]})")
        req = f"{r['requests']} / {o.get('requests', '-')} ({r['errors']}/{o.get('errors', '-')})"
        print(f"| {lab} | {req} | {pc(o.get('prefill_hit'))} -> {pc(r['prefill_hit'])} | {f(o.get('total_tok_s'), 0)} -> {f(r['total_tok_s'], 0)} | "
              f"{f(o.get('output_tok_s'), 1)} -> {f(r['output_tok_s'], 1)} | {f(o.get('rpm'), 1)} -> {f(r['rpm'], 1)} | "
              f"{f(o.get('ttft_p50'))} / {f(o.get('ttft_p95'))} s -> {f(r['ttft_p50'])} / {f(r['ttft_p95'])} s | "
              f"{f(o.get('itl_p50'), 3)} -> {f(r['itl_p50'], 3)} s | {fmt_counters(deltas(eon, r.get('t0'), r.get('t1'), a.grace))} |")
    for arm, d in (("on", a.on), ("off", a.off)):
        sl = os.path.join(d, "bench", "stage.log")
        if os.path.exists(sl):
            for l in open(sl):
                if "integrity rc=" in l or "SUMMARY" in l:
                    print(f"\nintegrity {arm}: " + l.strip()[:600])
    for arm, d in (("on", a.on), ("off", a.off)):
        print(f"\n### final counters, {arm} arm")
        for name, (series, warn, err, refused) in engines(d).items():
            ranks = sorted({r for (_, r) in series})
            fin = {w: (series[(w, 0)][-1][1] if (w, 0) in series else {}) for w in ("push", "landing", "recall")}
            print(f"- {name}: ranks {len(ranks)}, warnings {warn}, errors {err}, refused lines {refused}; " + "; ".join(f"{w} " + " ".join(f"{k}={v}" for k, v in kv.items()) for w, kv in fin.items() if kv))
    # route check summary
    bad = [k for k, r in list(on.items()) + list(off.items()) if r.get("route_ok") is False]
    print(f"\nroute_ok false on: {bad if bad else 'none'}")


if __name__ == "__main__":
    main()
