#!/usr/bin/env python3
"""Re-run point_metrics.py over a pulled job's bench dir, keeping each point's t0/t1/expect/kind/phase from its
points.jsonl, and write bench/points_fixed.jsonl (used after an in-job harness fix; the raw jsonl and snaps are the
source of truth). recompute_points.py <job>/pd1992/bench"""
import json, os, subprocess, sys
b = sys.argv[1]; out = os.path.join(b, "points_fixed.jsonl")
if os.path.exists(out): os.remove(out)
here = os.path.dirname(os.path.abspath(__file__))
for l in open(os.path.join(b, "points.jsonl")):
    if not l.startswith("{"): continue
    p = json.loads(l); base = os.path.join(b, f"{p['run']}_{p['label']}")
    subprocess.run([sys.executable, os.path.join(here, "point_metrics.py"), "--run", p["run"], "--label", p["label"], "--phase", p.get("phase", "all"),
                    "--expect", p.get("expect", "any"), "--t0", p.get("t0", ""), "--t1", p.get("t1", ""), "--kind", p.get("kind", "recall"),
                    "--jsonl", base + ".jsonl", "--m0", base + ".m0", "--m1", base + ".m1", "--out", out], check=True, stdout=subprocess.DEVNULL)
print(out)
