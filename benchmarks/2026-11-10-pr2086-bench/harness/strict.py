#!/usr/bin/env python3
"""Strict audit of workload records: a request counts as failed when it has an
error OR produced no completion tokens (a stream that ended early is recorded
by the clients with error=None). strict.py <jsonl> [<jsonl> ...]"""
import json
import sys

total = failed = 0
first = None
for path in sys.argv[1:]:
    try:
        rows = [json.loads(l) for l in open(path) if l.lstrip().startswith("{")]
    except FileNotFoundError:
        continue
    for r in rows:
        if "completion_tokens" not in r and "error" not in r:
            continue
        total += 1
        if r.get("error") not in (None, "None") or not r.get("completion_tokens"):
            failed += 1
            first = first or str(r.get("error") or "no completion tokens")[:120]
print(f"requests={total} failed={failed}" + (f" first={first}" if first else ""))
