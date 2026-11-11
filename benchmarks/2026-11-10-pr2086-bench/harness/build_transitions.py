#!/usr/bin/env python3
"""2P2D transitions: routing and recall table (off -> on) in addition to build_report.py's four tables.

build_transitions.py --on <job-output>/pd1992 --off <job-output>/pd1992
One row per point: expected pair, route_ok on both arms, which engines served the on arm's requests, prefill-side hit
off -> on, TTFT p50 off -> on with speedup, wall off -> on, and what the on arm pulled from decode DRAM (sum over
both prefills) during the point.
"""
import argparse, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_report as br  # noqa: E402


def speed(o_, n_):
    return "-" if not o_ or not n_ else f"{o_/n_:.1f}x"


def served(r):
    s = r.get("served") or {}
    parts = []
    for k in sorted(s):
        v = s[k]["requests"] if isinstance(s[k], dict) else s[k]
        if v:
            parts.append(f"{k.replace('prefill-', 'p').replace('decode-', 'd')}:{v}")
    return " ".join(parts) or "-"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--on", required=True); ap.add_argument("--off", required=True); ap.add_argument("--grace", type=float, default=45.0)
    a = ap.parse_args()
    on, off = br.load_points(a.on), br.load_points(a.off)
    eon = br.engines(a.on)
    print("**Routing and recall per point** (expected pair from the brief; served = requests per engine on the on arm; recalled = tokens the on arm's prefills pulled from decode DRAM during the point).\n")
    print("| Point | Expected pair | route_ok off / on | Served (on) | Prefill-side hit off -> on | TTFT p50 off -> on | Speedup | Wall s off -> on | Recalled from decode DRAM (on) |")
    print("|---|---|---|---|---|---|---|---|---|")
    for key, r in on.items():
        o = off.get(key, {})
        lab = f"{key[0]}" + ("" if key[1] in ("all", None) else f" ({key[1]})")
        dl = br.deltas(eon, r.get("t0"), r.get("t1"), a.grace, r.get("phase"))
        print(f"| {lab} | {r.get('expect', '-')} | {o.get('route_ok', '-')} / {r.get('route_ok', '-')} | {served(r)} | "
              f"{br.pc(o.get('prefill_hit'))} -> {br.pc(r.get('prefill_hit'))} | {br.f(o.get('ttft_p50'))} -> {br.f(r.get('ttft_p50'))} s | "
              f"{speed(o.get('ttft_p50'), r.get('ttft_p50'))} | "
              f"{br.f(o.get('wall_s'))} -> {br.f(r.get('wall_s'))} | {br.fmt_recalled(dl)} |")


if __name__ == "__main__":
    main()
