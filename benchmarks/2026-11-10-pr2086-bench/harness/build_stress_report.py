#!/usr/bin/env python3
"""Markdown tables for one stress run from its bench files (and, if present, the VM-side memory samples).

build_stress_report.py <bench-dir> [--mem mem.log] [--name label]
Reads <run>_stress_levels.jsonl, _stress_cycles.json, _stress_verdict.json, _stress_requests.jsonl, _stress_gsm8k_*.json
and prints: the ramp table per cycle (concurrency, requests, errors, hangs, TTFT, E2E, hit, GSM8K, prompt/image extremes,
engine gauges), the verification table per cycle, the request mix, TTFT by request bucket, and the per-pod memory
peak per level when a mem.log (kubectl top samples: "<ts> <pod> <container> <cpu> <mem>Mi") is given.
"""
import argparse, collections, glob, json, os, statistics
from datetime import datetime


def load_jsonl(p):
    return [json.loads(l) for l in open(p) if l.strip().startswith("{")] if p and os.path.exists(p) else []


def one(pattern):
    m = glob.glob(pattern)
    return m[0] if m else None


def f(x, nd=1):
    return "-" if x is None else f"{x:.{nd}f}"


def pct(x):
    return "-" if x is None else f"{100*x:.1f}%"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bench"); ap.add_argument("--mem"); ap.add_argument("--name", default="")
    a = ap.parse_args()
    b = a.bench
    levels = load_jsonl(one(os.path.join(b, "*_stress_levels.jsonl")))
    reqs = load_jsonl(one(os.path.join(b, "*_stress_requests.jsonl")))
    cyc = json.load(open(one(os.path.join(b, "*_stress_cycles.json")))) if one(os.path.join(b, "*_stress_cycles.json")) else {"cycles": []}
    ver = json.load(open(one(os.path.join(b, "*_stress_verdict.json")))) if one(os.path.join(b, "*_stress_verdict.json")) else {}
    base = json.load(open(one(os.path.join(b, "*_stress_gsm8k_baseline.json")))) if one(os.path.join(b, "*_stress_gsm8k_baseline.json")) else {}

    # memory samples: per pod, max MiB within each level's time window
    mem = collections.defaultdict(list)
    if a.mem and os.path.exists(a.mem):
        for l in open(a.mem):
            p = l.split()
            if len(p) >= 5 and p[4].endswith("Mi") and "gcsfuse" not in p[2]:
                ts = datetime.strptime(p[0], "%Y-%m-%dT%H:%M:%SZ")
                # pods are <jobset>-<role>-<engine>-<host>-<hash>; single-host engines have host 0
                parts = p[1].split("-")
                if parts[-4] not in ("prefill", "decode"):
                    continue  # router / bench pods are not engines
                role = f"{parts[-4]}-{parts[-3]}-h{parts[-2]}"
                mem[role].append((ts, int(p[4][:-2])))

    def mem_peak(t0, t1):
        out = {}
        for role, s in mem.items():
            v = [m for ts, m in s if t0 <= ts <= t1 + (t1 - t0) * 0 ]  # samples inside the level
            if not v:
                v = [m for ts, m in s if abs((ts - t1).total_seconds()) <= 330]  # or the sample right after it
            if v:
                out[role] = max(v) / 1024
        return out

    print(f"**Verdict{(' ' + a.name) if a.name else ''}:** {'PASS' if ver.get('ok') else 'FAIL' if ver else 'no verdict file (run did not finish)'}"
          + (f"; reasons: {ver.get('reasons')}" if ver.get("reasons") else "")
          + (f"; duration {ver.get('duration_s')} s, cycles {ver.get('cycles')}, last good concurrency per cycle {ver.get('last_good_conc')}, ramp ended at {ver.get('failed_at')} ({ver.get('fail_reasons')})" if ver else "")
          + (f"; GSM8K baseline {base.get('acc')} on {base.get('n')}" if base else "") + ".\n")
    if ver.get("health_slow_events"):
        print(f"Slow health probes (an engine took more than 30 s to answer /health, recovered): {ver['health_slow_events']}; "
              f"slowest successful answer per endpoint: { {k: v for k, v in (ver.get('health_latency_max_s') or {}).items() if v > 5} }.\n")

    print("**Ramp** (one row per level; a level holds its concurrency for the step time; hit = client-reported cached share; GSM8K = inline questions correct).\n")
    cols = "| Cycle | Level | Concurrency | Requests | Errors | Hangs | TTFT p50 s | TTFT p95 s | E2E p95 s | Hit | GSM8K | Max prompt tokens | Max images | Aborts | Engines running / queued at level end"
    if mem:
        cols += " | Peak RSS GB per pod"
    print(cols + " | Outcome |")
    print("|" + "---|" * (cols.count("|") + 1))
    for r in levels:
        eng = r.get("engines") or {}
        es = ", ".join(f"{k} {int(v.get('num_running_reqs', 0))}/{int(v.get('num_queue_reqs', 0))}" for k, v in eng.items())
        gs = "-" if r["gsm8k_acc"] is None else "%.2f" % r["gsm8k_acc"]
        row = (f"| {r['cycle']} | {r['level']} | {r['conc']} | {r['requests']} | {r['errors']} | {r['hangs']} | {f(r['ttft_p50'])} | {f(r['ttft_p95'])} | "
               f"{f(r['e2e_p95'])} | {pct(r['client_hit'])} | {gs} ({r['gsm8k_n']}) | "
               f"{r['max_prompt_tokens']:,} | {r['max_images']} | {r['aborts']} | {es}")
        if mem:
            t1 = datetime.strptime(r["t"], "%Y-%m-%d %H:%M:%S")
            t0 = t1 - __import__("datetime").timedelta(seconds=r.get("hold_s", 300))
            pk = mem_peak(t0, t1)
            row += " | " + ", ".join(f"{k} {v:.0f}" for k, v in sorted(pk.items()))
        out = "pass" if not r.get("fail") and r["error_rate"] <= 0.05 and not r["hangs"] else ("FAIL: " + (r.get("fail") or (f"error rate {r['error_rate']:.3f}" if r["error_rate"] > 0.05 else "hangs")))[:120]
        print(row + f" | {out} |")

    print("\n**Drain and verification per cycle** (after the ramp stops: in-flight requests finish, every engine idle, a verification batch, the GSM8K gate against the idle baseline, then a flush and the leak check).\n")
    print("| Cycle | Ramp ended at | Why | Drain s | Idle after drain | Verification batch ok / sent | Batch TTFT p50 s | GSM8K acc (baseline) | Predictions changed | Token usage after flush | Bootstrap failures | Verdict |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for c in cyc.get("cycles", []):
        v = c.get("verify") or {}
        vb = v.get("verify") or {}
        g = v.get("gsm8k") or {}
        print(f"| {c['cycle']} | {c.get('failed_at') or c.get('last_good_conc')} | {(c.get('fail_reason') or '')[:90]} | {v.get('drain_s')} | {v.get('idle')} {v.get('busy_after_drain') or ''} | "
              f"{vb.get('ok')} / {vb.get('requests')} | {f(vb.get('ttft_p50'))} | {g.get('acc')} ({g.get('baseline_acc')}) | {g.get('pred_changed')} of {g.get('compared')} | "
              f"{v.get('token_usage_after_flush')} | {v.get('bootstrap_failed_total')} | {'PASS' if v.get('ok') else 'FAIL ' + '; '.join(v.get('reasons', []))[:120]} |")

    if reqs:
        ok = [r for r in reqs if r["ok"]]
        print(f"\n**Requests:** {len(reqs)} sent, {len(ok)} ok, {len(reqs) - len(ok)} failed, {sum(1 for r in reqs if r.get('hang'))} hangs; "
              f"kinds {dict(collections.Counter(r['kind'] for r in reqs))}; buckets {dict(collections.Counter(r.get('bucket') for r in reqs))}; "
              f"{sum(1 for r in reqs if r.get('images'))} requests with images (max {max((r.get('images') or 0) for r in reqs)}), "
              f"max prompt {max((r.get('prompt_tokens') or 0) for r in reqs):,} tokens, max output {max(r['out_tokens'] for r in reqs)} tokens, "
              f"{sum(1 for r in reqs if r['turn'] > 1)} session returns, {sum(1 for r in reqs if r.get('abort'))} client aborts.\n")
        by = collections.defaultdict(list)
        for r in ok:
            if r.get("ttft_s") is not None:
                by[r.get("bucket")].append(r["ttft_s"])
        print("| Bucket | Requests | TTFT p50 s | TTFT p95 s |")
        print("|---|---|---|---|")
        for k in ("short", "medium", "long", "xlong", "return", "gsm8k"):
            v = sorted(by.get(k, []))
            if v:
                print(f"| {k} | {len(v)} | {v[len(v)//2]:.1f} | {v[int(0.95*(len(v)-1))]:.1f} |")
        bad = collections.Counter((r["level"], r["kind"], (r["why"] or "")[:60]) for r in reqs if not r["ok"])
        if bad:
            print("\nFailed requests by level and reason: " + "; ".join(f"L{l} {k}: {n} x {w}" for (l, k, w), n in bad.most_common(8)))


if __name__ == "__main__":
    main()
