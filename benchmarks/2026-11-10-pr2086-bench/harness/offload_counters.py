#!/usr/bin/env python3
"""Offload counters and rank consistency from the PR 2086 server logs.

The engines log cumulative counters at most every 30 s as
  [YYYY-mm-dd HH:MM:SS TPr EPr] [dram-offload] push started=.. stored=.. declined=..          (prefill)
  [...] [dram-offload] landing received=.. granted=.. no_room=.. landed=.. landed_tokens=.. failed=.. dropped=..  (decode)
  [...] [dram-offload] recall offers=.. pulls=.. pulled_tokens=.. pulled_swa_tokens=.. skipped_local_host=.. no_memory=.. over_budget=.. adopted_backup_tokens=.. failed=..  (prefill)
(zero-valued keys are omitted). For every log: the final counters of TP0, whether every rank reports the same
counters (B3 rank consistency), refused pulls, warnings and errors. With --points <points.jsonl> (t0/t1 per point from
point_metrics.py), the per-point deltas of the TP0 counters (see window(): end = first line at or after t1; start = last line at or
before t0 for a return phase, first line at or after t0 for a point that begins with a wipe).

offload_counters.py [--points points.jsonl] [--grace 45] [--json out.json] <server.log> ...
"""
import argparse, json, os, re, sys
from collections import defaultdict
from datetime import datetime, timedelta

LINE = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)(?: TP(\d+))?(?: EP\d+)?\] \[dram-offload\] (push|landing|recall) ?(.*)$")
WARN = re.compile(r"Cannot register host read|Cannot start host read|did not settle|Cannot poll host read|failed \(errno")
ERR = re.compile(r"Traceback|Scheduler hit an exception|RuntimeError|AssertionError|KeyError|out of memory|malformed|DEADLINE_EXCEEDED|subtree drop declined")
REFUSED = re.compile(r"refus", re.I)
KEYS = {"push": ["started", "stored", "declined"],
        "landing": ["received", "granted", "no_room", "landed", "landed_tokens", "failed", "dropped"],
        "recall": ["offers", "pulls", "pulled_tokens", "pulled_swa_tokens", "skipped_local_host", "no_memory", "over_budget", "adopted_backup_tokens", "failed"]}


def parse(path):
    series = defaultdict(list)  # (what, rank) -> [(ts, {k: v})]
    warn = err = refused = 0
    for line in open(path, errors="ignore"):
        m = LINE.match(line)
        if m:
            ts = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
            rank = int(m.group(2) or 0)
            kv = {}
            for tok in m.group(4).split():
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    try:
                        kv[k] = int(v)
                    except ValueError:
                        kv[k] = v
            series[(m.group(3), rank)].append((ts, kv))
            continue
        if WARN.search(line): warn += 1
        if ERR.search(line): err += 1
        if REFUSED.search(line) and "dram" in line: refused += 1
    return series, warn, err, refused


def value_at(points, ts, side="before"):
    """Counters at time ts from the cumulative lines (logged every 30 s while there is activity).
    side="before": the last line at or before ts (nothing after ts is counted, events logged late are included);
    side="after": the first line at or after ts (events in the <= 30 s after ts are included). Falls back to the
    other side when none exists."""
    before, after = {}, None
    for t, kv in points:
        if t <= ts:
            before = kv
        elif after is None:
            after = kv
    if side == "after":
        return after if after is not None else before
    return before


def window(points, t0, t1, starts_after_wipe):
    """Delta of the TP0 counters over a point. The end is the first line at or after t1 (the point's own late-logged
    events are never lost). The start is the last line at or before t0 for a return phase (its recalls begin at
    once) and the first line at or after t0 for a point that begins with a wipe (fill, static, mixed: nothing it does
    in its first seconds can push or recall, so a burst logged there belongs to the previous point)."""
    v0 = value_at(points, t0, "after" if starts_after_wipe else "before")
    v1 = value_at(points, t1, "after")
    return v0, v1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--points"); ap.add_argument("--grace", type=float, default=45.0); ap.add_argument("--json")
    ap.add_argument("logs", nargs="+")
    a = ap.parse_args()
    report = {"engines": {}, "points": []}
    engines = {}
    for path in a.logs:
        name = os.path.basename(os.path.dirname(path)) or path
        series, warn, err, refused = parse(path)
        engines[name] = series
        ranks = sorted({r for (_, r) in series})
        whats = sorted({w for (w, _) in series})
        e = {"ranks": len(ranks), "warnings": warn, "errors": err, "refused_lines": refused, "final": {}, "rank_equal": True, "unequal": []}
        print(f"== {name} ranks={len(ranks)} warnings={warn} errors={err} refused_lines={refused}")
        for w in whats:
            finals = {r: (series[(w, r)][-1][1] if series.get((w, r)) else {}) for r in ranks}
            tp0 = finals.get(0, {})
            e["final"][w] = tp0
            print(f"  {w:8s} TP0 final: " + " ".join(f"{k}={tp0.get(k, 0)}" for k in KEYS[w] if k in tp0 or k in ("started", "stored", "landed", "pulls")))
            for k in KEYS[w]:
                vals = {r: finals[r].get(k, 0) for r in ranks}
                if len(set(vals.values())) > 1:
                    e["rank_equal"] = False; e["unequal"].append(f"{w}.{k}")
                    print(f"    {w}.{k} differs across ranks: " + " ".join(f"TP{r}={v}" for r, v in vals.items()))
        print(f"  verdict: {'EQUAL' if e['rank_equal'] else 'UNEQUAL'} across {len(ranks)} ranks")
        report["engines"][name] = e

    if a.points and os.path.exists(a.points):
        grace = timedelta(seconds=a.grace)
        print("== per-point TP0 counter deltas (t0 .. t1+grace)")
        for l in open(a.points):
            if not l.startswith("{"):
                continue
            p = json.loads(l)
            if not p.get("t0") or not p.get("t1"):
                continue
            t0 = datetime.strptime(p["t0"], "%Y-%m-%d %H:%M:%S"); t1 = datetime.strptime(p["t1"], "%Y-%m-%d %H:%M:%S")
            row = {"label": p["label"], "phase": p.get("phase"), "deltas": {}}
            parts = []
            for name, series in engines.items():
                for w in ("push", "recall", "landing"):
                    if (w, 0) not in series:
                        continue
                    v0, v1 = window(series[(w, 0)], t0, t1, p.get("phase") != "recall")
                    d = {k: v1.get(k, 0) - v0.get(k, 0) for k in KEYS[w] if (v1.get(k, 0) - v0.get(k, 0))}
                    if d:
                        row["deltas"][f"{name}.{w}"] = d
                        parts.append(f"{name} {w}: " + " ".join(f"{k}={v}" for k, v in d.items()))
            print(f"  {p['label']}/{p.get('phase')}: " + ("; ".join(parts) if parts else "no counter movement"))
            report["points"].append(row)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(report, f, indent=1)


if __name__ == "__main__":
    main()
