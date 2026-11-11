#!/usr/bin/env python3
"""Prefill-side prefix hit of one workload case: sum of '#cached-token' over '#cached-token + #new-token' in the prefill
batch log lines of every prefill host, within the case's request window (first t_start .. last t_start + e2e).
prefill_hit_window.py <case jsonl> <prefill log> [<prefill log> ...]"""
import json, re, sys
from datetime import datetime, timezone

rows = [json.loads(l) for l in open(sys.argv[1]) if l.startswith("{")]
rec = [r for r in rows if r.get("phase") == "recall"] or rows
t0 = min(r["t_start"] for r in rec) - 1
t1 = max(r["t_start"] + (r.get("e2e_s") or 0) for r in rec) + 1
pat = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) TP0 .*Prefill batch, #new-seq: \d+, #new-token: (\d+), #cached-token: (\d+)")
cached = new = 0
for path in sys.argv[2:]:
    for line in open(path, errors="ignore"):
        m = pat.match(line)
        if not m:
            continue
        ts = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
        if t0 <= ts <= t1:
            new += int(m.group(2)); cached += int(m.group(3))
total = cached + new
print(f"prefill-side hit {100*cached/total if total else 0:.1f}% (cached {cached} of {total} prompt tokens, {len(rec)} requests)")
