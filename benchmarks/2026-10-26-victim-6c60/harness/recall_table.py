#!/usr/bin/env python3
"""Before/after table from chain logs: prefill hit (metrics deltas), decode reuse, TTFT, throughput, victim counters."""
import json, re, sys
from pathlib import Path
R = Path.home() / "pd_disagg/spill/results_recall"
def deltas(log):
    v = {}
    for l in open(log):
        m = re.search(r'\[(\S+) (pre|mid|post)\]\s+(prefill|decode) sglang:(cached|prompt)_tokens_total (\d+)', l)
        if m: v[(m[1], m[2], m[3], m[4])] = int(m[5])
    vic = {}
    for l in open(log):
        m = re.search(r'\[(\S+) post\]\s+(prefill push|decode push|prefix-pull commits \(TP0\)|prefix-pull tokens \(TP0\)):\s*(.*)', l)
        if m: vic.setdefault(m[1], {})[m[2]] = m[3].strip()
    return v, vic
def get(v, lab, ph, role, k):
    a, b = ("pre", "mid") if ph == "fill" else ("mid", "post")
    return v.get((lab, b, role, k), 0) - v.get((lab, a, role, k), 0)
rows = []
for cfg, run, logs in [("before", "recall_before_1", ["chain_recall_before.log", "chain_recall_before_extra.log"]), ("after", "recall_after_ab_1", ["chain_recall_after_ab.log"])]:
    v, vic = {}, {}
    for log in logs:
        p = Path.home() / "pd_disagg/spill/logs" / log
        if p.exists():
            a, b = deltas(p); v.update(a); vic.update(b)
    for f in sorted(R.glob(f"{run}_*_recall.summary.json")):
        s = json.loads(f.read_text()); lab = s["label"].rsplit("_", 1)[0]
        fs = R / f.name.replace("_recall.summary", "_fill.summary")
        fill = json.loads(fs.read_text())["fill"] if fs.exists() else {}
        rc = s["recall"]
        pp, pc = get(v, lab, "recall", "prefill", "prompt"), get(v, lab, "recall", "prefill", "cached")
        rows.append(dict(cfg=cfg, point=lab, sessions=s["sessions"], ws_M=round(s["working_set_tokens"]/1e6, 2),
            prefill_hit=round(pc/pp, 3) if pp else None, decode_reuse=rc["token_hit_rate"],
            ttft50=round(rc["ttft_p50"], 2), ttft95=round(rc["ttft_p95"], 2), e2e50=round(rc["e2e_p50"], 2),
            tok_s=rc["total_tok_s"], out_tok_s=rc["output_tok_s"], wall=rc["wall_s"], err=rc["errors"],
            fill_ttft50=round(fill.get("ttft_p50") or 0, 2), **{k: vic.get(lab, {}).get(k, "") for k in ("prefill push", "decode push", "prefix-pull commits (TP0)", "prefix-pull tokens (TP0)")}))
keys = ["cfg","point","sessions","ws_M","prefill_hit","decode_reuse","ttft50","ttft95","e2e50","tok_s","out_tok_s","wall","err","fill_ttft50"]
print(" | ".join(keys))
for r in sorted(rows, key=lambda r: (r["point"].split("_s")[0], r["sessions"], r["cfg"])): print(" | ".join(str(r[k]) for k in keys))
if any(r["cfg"]=="after" for r in rows):
    print("\nvictim counters (after, cumulative):")
    for r in rows:
        if r["cfg"]=="after": print(f"  {r['point']}: push[{r['prefill push']}] decode[{r['decode push']}] pulls={r['prefix-pull commits (TP0)']} pulled_tokens={r['prefix-pull tokens (TP0)']}")
