#!/usr/bin/env python3
"""B3 rank consistency and transfer evidence from one server log (prefill or decode):
per-rank count of committed pulls ('[prefix-pull] room=' lines), per-rank last '[victim-push] role=...' counters,
SWA tokens moved (hybrid models), and a verdict: EQUAL when every rank logged the same counts.
rank_consistency.py <server.log> [<server.log> ...]"""
import re, sys
from collections import Counter, defaultdict

RANK = re.compile(r"^\[(\S+ \S+) TP(\d+)")
PULL = re.compile(r"\[prefix-pull\] room=\S+ (.*)$")
PUSH = re.compile(r"\[victim-push\] role=(\w+) (.*)$")
for path in sys.argv[1:]:
    pulls, pulled, swa, inserted = Counter(), Counter(), Counter(), Counter()
    last_push = {}
    role = None
    for line in open(path, errors="ignore"):
        m = RANK.match(line)
        if not m:
            continue
        rank = int(m.group(2))
        p = PULL.search(line)
        if p:
            kv = dict(x.split("=", 1) for x in p.group(1).split() if "=" in x and not x.startswith("totals"))
            pulls[rank] += 1; pulled[rank] += int(kv.get("pulled_tokens", 0) or 0); swa[rank] += int(kv.get("swa_tokens", 0) or 0)
            inserted[rank] += kv.get("inserted") == "True"
        q = PUSH.search(line)
        if q:
            role = q.group(1); last_push[rank] = dict(kv.split("=", 1) for kv in q.group(2).split() if "=" in kv)
    ranks = sorted(set(pulls) | set(last_push))
    print(f"== {path} role={role or '?'} ranks={len(ranks)}")
    if pulls:
        print("  pulls per rank: " + " ".join(f"TP{r}={pulls[r]}" for r in ranks) + f"  pulled_tokens TP0={pulled[0]} swa_tokens TP0={swa[0]} inserted TP0={inserted[0]}")
    if last_push:
        keys = sorted({k for d in last_push.values() for k in d})
        for k in keys:
            vals = [last_push.get(r, {}).get(k, "-") for r in ranks]
            flag = "" if len(set(vals)) == 1 else "  <-- differs across ranks"
            print(f"  {k:28s} " + " ".join(f"TP{r}={v}" for r, v in zip(ranks, vals)) + flag)
    equal = len({pulls[r] for r in ranks}) <= 1 and all(len({last_push.get(r, {}).get(k) for r in ranks}) <= 1 for k in {k for d in last_push.values() for k in d})
    print(f"  verdict: {'EQUAL' if equal else 'UNEQUAL'} across {len(ranks)} ranks" + ("" if swa[0] == 0 else f"; SWA tokens recalled on TP0: {swa[0]}"))
