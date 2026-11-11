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
    p = os.path.join(d, "bench", "points_fixed.jsonl")
    if not os.path.exists(p):
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
    if a.get("recall.offers") or a.get("recall.pulls"): parts.append(f"recall {a.get('recall.pulls', 0)}/{a.get('recall.offers', 0)} offers" + (f" fail {a['recall.failed']}" if a.get("recall.failed") else "") + (f" skipped_local {a['recall.skipped_local_host']}" if a.get("recall.skipped_local_host") else ""))
    return "; ".join(parts) or "none"


def fmt_recalled(a):
    """Recalled KV: tokens pulled from decode DRAM into the prefill during the point, plus their SWA window tokens."""
    if not a or not (a.get("recall.pulled_tokens") or a.get("recall.pulls")):
        return "0"
    s = f"{a.get('recall.pulled_tokens', 0):,} tok in {a.get('recall.pulls', 0)} pulls"
    if a.get("recall.pulled_swa_tokens"):
        s += f" + {a.get('recall.pulled_swa_tokens', 0):,} SWA"
    return s


def fmt_tiers(r):
    t = r.get("client_cached_by_tier") or {}
    if not t or not any(t.values()):
        return "0 / 0"
    return f"{t.get('device', 0)/1e6:.2f}M / {t.get('host', 0)/1e6:.2f}M"


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
    def gain(o_, n_, lower_better=False):
        """Signed improvement in percent: throughput up = +, latency down = +."""
        if o_ is None or n_ is None or not o_:
            return "-"
        g = (o_ - n_) / o_ if lower_better else (n_ - o_) / o_
        return f"{100*g:+.0f}%"

    def pp(o_, n_):
        if o_ is None or n_ is None:
            return "-"
        return f"{100*(n_ - o_):+.1f} pp"

    rows = []
    for key, r in on.items():
        o = off.get(key, {})
        lab = f"{key[0]}" + ("" if key[1] in ("all", None) else f" ({key[1]})")
        rows.append((lab, r, o, deltas(eon, r.get("t0"), r.get("t1"), a.grace)))

    def speed(o_, n_):
        return "-" if not o_ or not n_ else f"{o_/n_:.1f}x"

    print("**Performance gain** (what a user of the pair sees; return rows are the requests whose prefix the previous turn produced).\n")
    print("| Point | TTFT p50 off -> on | Speedup | TTFT p95 off -> on | Speedup | E2E p50 off -> on | Wall s off -> on | Gain | Req/min off -> on | Gain | Warm returns off -> on | Prefill tokens computed per request, off -> on |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for lab, r, o, dl in rows:
        print(f"| {lab} | {f(o.get('ttft_p50'))} -> {f(r['ttft_p50'])} s | {speed(o.get('ttft_p50'), r['ttft_p50'])} | "
              f"{f(o.get('ttft_p95'))} -> {f(r['ttft_p95'])} s | {speed(o.get('ttft_p95'), r['ttft_p95'])} | "
              f"{f(o.get('e2e_p50'))} -> {f(r['e2e_p50'])} s | {f(o.get('wall_s'))} -> {f(r['wall_s'])} | {gain(o.get('wall_s'), r['wall_s'], True)} | "
              f"{f(o.get('rpm'), 1)} -> {f(r['rpm'], 1)} | {gain(o.get('rpm'), r['rpm'])} | "
              f"{o.get('warm_sessions', '-')} / {o.get('requests', '-')} -> {r.get('warm_sessions', '-')} / {r['requests']} | "
              f"{o.get('recomputed_tokens_per_req', '-'):,} -> {r.get('recomputed_tokens_per_req', '-'):,} |" if isinstance(o.get('recomputed_tokens_per_req'), int) and isinstance(r.get('recomputed_tokens_per_req'), int) else
              f"| {lab} | {f(o.get('ttft_p50'))} -> {f(r['ttft_p50'])} s | {speed(o.get('ttft_p50'), r['ttft_p50'])} | {f(o.get('ttft_p95'))} -> {f(r['ttft_p95'])} s | {speed(o.get('ttft_p95'), r['ttft_p95'])} | {f(o.get('e2e_p50'))} -> {f(r['e2e_p50'])} s | {f(o.get('wall_s'))} -> {f(r['wall_s'])} | {gain(o.get('wall_s'), r['wall_s'], True)} | {f(o.get('rpm'), 1)} -> {f(r['rpm'], 1)} | {gain(o.get('rpm'), r['rpm'])} | {o.get('warm_sessions', '-')} / {o.get('requests', '-')} -> {r.get('warm_sessions', '-')} / {r['requests']} | - |")

    print("\n**Cache (mechanism)**: prefill-side hit, client-reported cached tokens, where the prefix was found, and what the on arm recalled from decode DRAM.\n")
    print("| Point | Requests on / off (errors) | Prefill-side hit off -> on | Gain | Client-reported hit off -> on | Cached by tier device / host, off -> on | Recalled from decode DRAM (on) |")
    print("|---|---|---|---|---|---|---|")
    for lab, r, o, dl in rows:
        req = f"{r['requests']} / {o.get('requests', '-')} ({r['errors']}/{o.get('errors', '-')})"
        print(f"| {lab} | {req} | {pc(o.get('prefill_hit'))} -> {pc(r['prefill_hit'])} | {pp(o.get('prefill_hit'), r['prefill_hit'])} | {pc(o.get('client_token_hit_rate'))} -> {pc(r.get('client_token_hit_rate'))} | {fmt_tiers(o)} -> {fmt_tiers(r)} | {fmt_recalled(dl)} |")

    print("\n**Throughput** (gain = on vs off, higher is better).\n")
    print("| Point | Total tok/s off | on | Gain | Output tok/s off | on | Gain | Req/min off | on | Gain |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for lab, r, o, dl in rows:
        print(f"| {lab} | {f(o.get('total_tok_s'), 0)} | {f(r['total_tok_s'], 0)} | {gain(o.get('total_tok_s'), r['total_tok_s'])} | "
              f"{f(o.get('output_tok_s'), 1)} | {f(r['output_tok_s'], 1)} | {gain(o.get('output_tok_s'), r['output_tok_s'])} | "
              f"{f(o.get('rpm'), 1)} | {f(r['rpm'], 1)} | {gain(o.get('rpm'), r['rpm'])} |")

    print("\n**Latency** (gain = reduction on vs off, positive means the on arm is faster).\n")
    print("| Point | TTFT p50 off | on | Gain | TTFT p95 off | on | Gain | ITL p50 off | on | Gain |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for lab, r, o, dl in rows:
        print(f"| {lab} | {f(o.get('ttft_p50'))} s | {f(r['ttft_p50'])} s | {gain(o.get('ttft_p50'), r['ttft_p50'], True)} | "
              f"{f(o.get('ttft_p95'))} s | {f(r['ttft_p95'])} s | {gain(o.get('ttft_p95'), r['ttft_p95'], True)} | "
              f"{f(o.get('itl_p50'), 3)} s | {f(r['itl_p50'], 3)} s | {gain(o.get('itl_p50'), r['itl_p50'], True)} |")

    print("\n**Offload counters on the on arm, per point** (TP0 deltas from the server logs; every push and landing is a 128k-session branch with its SWA window).\n")
    print("| Point | Pushes stored / started | Landings landed / received | Recalls pulls / offers | Pulled tokens | SWA tokens | Failed / refused / no room |")
    print("|---|---|---|---|---|---|---|")
    for lab, r, o, dl in rows:
        g = lambda k: dl.get(k, 0)
        print(f"| {lab} | {g('push.stored')} / {g('push.started')} | {g('landing.landed')} / {g('landing.received')} | {g('recall.pulls')} / {g('recall.offers')} | "
              f"{g('recall.pulled_tokens'):,} | {g('recall.pulled_swa_tokens'):,} | {g('recall.failed') + g('landing.failed')} / {g('push.declined')} / {g('landing.no_room')} |")
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
