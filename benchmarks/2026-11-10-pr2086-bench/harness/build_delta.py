#!/usr/bin/env python3
"""Head-to-head table of one campaign on two PR heads: per point, the off -> on numbers on the old head and on the
new head, and what the new head changed on the on arm (hit, TTFT p50, total tok/s, req/min).

build_delta.py --old-on <dir> --old-off <dir> --new-on <dir> --new-off <dir> [--old-name 54a8086] [--new-name 83198bc]
Each <dir> holds points_fixed.jsonl or points.jsonl (point_metrics.py lines) directly or under bench/.
"""
import argparse, json, os


def load(d):
    pts = {}
    for name in ("points_fixed.jsonl", "points.jsonl"):
        for p in (os.path.join(d, name), os.path.join(d, "bench", name)):
            if os.path.exists(p):
                for l in open(p):
                    if l.startswith("{"):
                        r = json.loads(l); pts[(r["label"], r.get("phase", "all"))] = r
                return pts
    return pts


def f(x, nd=1):
    return "-" if x is None else f"{x:.{nd}f}"


def pc(x):
    return "-" if x is None else f"{100*x:.1f}%"


def gain(o, n, lower_better=False):
    if not o or n is None:
        return "-"
    g = (o - n) / o if lower_better else (n - o) / o
    return f"{100*g:+.0f}%"


def pp(o, n):
    return "-" if o is None or n is None else f"{100*(n-o):+.1f} pp"


def main():
    ap = argparse.ArgumentParser()
    for k in ("old-on", "old-off", "new-on", "new-off"):
        ap.add_argument("--" + k, required=True)
    ap.add_argument("--old-name", default="54a8086"); ap.add_argument("--new-name", default="83198bc")
    a = ap.parse_args()
    oo, of, no, nf = load(a.old_on), load(a.old_off), load(a.new_on), load(a.new_off)
    keys = [k for k in no if k in oo]
    print(f"| Point | Prefill-side hit, {a.old_name}: off -> on | {a.new_name}: off -> on | On arm, hit {a.old_name} -> {a.new_name} | "
          f"TTFT p50 s, {a.old_name}: off -> on | {a.new_name}: off -> on | On arm TTFT change | Total tok/s on arm {a.old_name} -> {a.new_name} | Req/min on arm {a.old_name} -> {a.new_name} |")
    print("|---|---|---|---|---|---|---|---|---|")
    for k in keys:
        lab = k[0] + ("" if k[1] in ("all", None) else f" ({k[1]})")
        o_on, o_off, n_on, n_off = oo[k], of.get(k, {}), no[k], nf.get(k, {})
        print(f"| {lab} | {pc(o_off.get('prefill_hit'))} -> {pc(o_on.get('prefill_hit'))} | {pc(n_off.get('prefill_hit'))} -> {pc(n_on.get('prefill_hit'))} | "
              f"{pp(o_on.get('prefill_hit'), n_on.get('prefill_hit'))} | "
              f"{f(o_off.get('ttft_p50'))} -> {f(o_on.get('ttft_p50'))} | {f(n_off.get('ttft_p50'))} -> {f(n_on.get('ttft_p50'))} | "
              f"{gain(o_on.get('ttft_p50'), n_on.get('ttft_p50'), True)} | "
              f"{f(o_on.get('total_tok_s'), 0)} -> {f(n_on.get('total_tok_s'), 0)} ({gain(o_on.get('total_tok_s'), n_on.get('total_tok_s'))}) | "
              f"{f(o_on.get('rpm'))} -> {f(n_on.get('rpm'))} ({gain(o_on.get('rpm'), n_on.get('rpm'))}) |")
    print("\n**Off arm drift** (the switch-off baseline should not move between heads; a move is noise or an unrelated change).\n")
    print(f"| Point | TTFT p50 off, {a.old_name} -> {a.new_name} | Total tok/s off | Prefill-side hit off |")
    print("|---|---|---|---|")
    for k in keys:
        lab = k[0] + ("" if k[1] in ("all", None) else f" ({k[1]})")
        o, n = of.get(k, {}), nf.get(k, {})
        print(f"| {lab} | {f(o.get('ttft_p50'))} -> {f(n.get('ttft_p50'))} ({gain(o.get('ttft_p50'), n.get('ttft_p50'), True)}) | "
              f"{f(o.get('total_tok_s'), 0)} -> {f(n.get('total_tok_s'), 0)} ({gain(o.get('total_tok_s'), n.get('total_tok_s'))}) | "
              f"{pc(o.get('prefill_hit'))} -> {pc(n.get('prefill_hit'))} |")


if __name__ == "__main__":
    main()
