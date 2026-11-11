#!/usr/bin/env python3
"""One benchmark point from a client jsonl and the two per-engine metric snapshots around it.

Prints "POINT {json}" and appends the json to --out. Fields: requests/errors, prefill-side hit (cached over prompt
tokens of every prefill engine between the snaps; the client-side token_hit_rate is decode-inflated with the switch
off), throughput (total_tok_s = (prompt + output tokens) / wall, output_tok_s, requests per minute), latency (TTFT
p50/p95, ITL p50 = (e2e - ttft) / (completion_tokens - 1), e2e p50), and the route: per-engine request deltas, checked
against --expect (p0d0 = prefill 0 and decode 0 served everything; any = no check).
"""
import argparse, json, re, sys


def pct(v, p):
    if not v:
        return None
    s = sorted(v)
    return s[max(0, min(len(s) - 1, int(round((len(s) - 1) * p))))]


def rnd(x):
    return None if x is None else round(x, 3)


def load_snap(p):
    d = {}
    try:
        for l in open(p):
            f = l.split()
            if len(f) == 3:
                d.setdefault(f[0], {})[f[1]] = float(f[2])
            elif len(f) == 2:  # old aggregate format
                d.setdefault("prefill-all", {})[f[0]] = float(f[1])
    except FileNotFoundError:
        pass
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True); ap.add_argument("--label", required=True)
    ap.add_argument("--phase", default="all", help="fill | recall | all (every record)")
    ap.add_argument("--kind", default="recall", help="recall | static | mixed")
    ap.add_argument("--expect", default="any"); ap.add_argument("--t0", default=""); ap.add_argument("--t1", default="")
    ap.add_argument("--jsonl", required=True); ap.add_argument("--m0", required=True); ap.add_argument("--m1", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    rows = []
    try:
        rows = [json.loads(l) for l in open(a.jsonl) if l.startswith("{")]
    except FileNotFoundError:
        pass
    if a.phase != "all":
        rows = [r for r in rows if r.get("phase") == a.phase]
    ok = [r for r in rows if not r.get("error") and r.get("completion_tokens")]
    err = len(rows) - len(ok)
    pt = sum(r.get("prompt_tokens") or 0 for r in ok)
    out = sum(r.get("completion_tokens") or 0 for r in ok)
    ct = sum(r.get("cached_tokens") or 0 for r in ok)
    starts = [r["t_start"] for r in rows if r.get("t_start")]
    ends = [r["t_start"] + (r.get("e2e_s") or 0) for r in rows if r.get("t_start")]
    wall = (max(ends) - min(starts)) if starts else 0.0
    if not wall:  # static_reuse.py records carry no t_start: take the client's wall from its summary
        try:
            summ = json.load(open(re.sub(r"\.jsonl$", ".summary.json", a.jsonl)))
            wall = float(summ.get("wall_s") or 0.0)
        except (FileNotFoundError, ValueError):
            pass
    ttft = [r["ttft_s"] for r in ok if r.get("ttft_s") is not None]
    e2e = [r["e2e_s"] for r in ok if r.get("e2e_s") is not None]
    itl = [(r["e2e_s"] - r["ttft_s"]) / (r["completion_tokens"] - 1) for r in ok
           if r.get("e2e_s") is not None and r.get("ttft_s") is not None and (r.get("completion_tokens") or 0) > 1]

    s0, s1 = load_snap(a.m0), load_snap(a.m1)
    served, pc, pp = {}, 0.0, 0.0
    for eng in sorted(set(s0) | set(s1)):
        d0, d1 = s0.get(eng, {}), s1.get(eng, {})
        delta = lambda k: d1.get(k, 0) - d0.get(k, 0)
        served[eng] = {"requests": int(delta("sglang:num_requests_total")), "prompt_tokens": int(delta("sglang:prompt_tokens_total")),
                       "generation_tokens": int(delta("sglang:generation_tokens_total"))}
        if eng.startswith("prefill"):
            pc += delta("sglang:cached_tokens_total"); pp += delta("sglang:prompt_tokens_total")
    hit = (pc / pp) if pp else None
    route_ok = None
    if a.expect != "any" and served:
        m = re.fullmatch(r"p(\d+)d(\d+)", a.expect)
        if m:
            want = {f"prefill-{m.group(1)}", f"decode-{m.group(2)}"}
            route_ok = all((v["requests"] == 0 and v["prompt_tokens"] == 0) for e, v in served.items() if e not in want) \
                and all(served.get(w, {}).get("requests", 0) > 0 or served.get(w, {}).get("prompt_tokens", 0) > 0 for w in want)

    d = {"run": a.run, "label": a.label, "kind": a.kind, "phase": a.phase, "t0": a.t0, "t1": a.t1,
         "requests": len(rows), "errors": err, "wall_s": round(wall, 1),
         "prompt_tokens": pt, "output_tokens": out, "client_cached_tokens": ct,
         "prefill_hit": None if hit is None else round(hit, 4), "prefill_cached_tokens": int(pc), "prefill_prompt_tokens": int(pp),
         "client_token_hit_rate": round(ct / pt, 4) if pt else None,
         "total_tok_s": round((pt + out) / wall, 1) if wall else None, "output_tok_s": round(out / wall, 1) if wall else None,
         "rpm": round(60 * len(ok) / wall, 2) if wall else None,
         "ttft_p50": rnd(pct(ttft, .5)), "ttft_p95": rnd(pct(ttft, .95)), "itl_p50": None if not itl else round(pct(itl, .5), 4),
         "itl_p95": None if not itl else round(pct(itl, .95), 4), "e2e_p50": rnd(pct(e2e, .5)), "e2e_p95": rnd(pct(e2e, .95)),
         "expect": a.expect, "route_ok": route_ok, "served": served}
    with open(a.out, "a") as f:
        f.write(json.dumps(d) + "\n")
    h = "n/a" if hit is None else f"{100*hit:.1f}%"
    print(f"POINT {json.dumps(d)}")
    print(f"  => {a.label}/{a.phase}: {len(rows)} req ({err} err) hit {h} total {d['total_tok_s']} tok/s out {d['output_tok_s']} tok/s "
          f"ttft p50 {d['ttft_p50']} p95 {d['ttft_p95']} itl p50 {d['itl_p50']} route_ok={route_ok} served={ {e: v['requests'] for e, v in served.items()} }")


if __name__ == "__main__":
    main()
