#!/usr/bin/env python3
"""ws2_table.py name=jobdir ... : per-point table (runs, mean, min..max) of prefill-side hit, TTFT p50 and total tok/s
for each arm, from bench/points.jsonl of each job (repeat labels _r<i> fold onto the base label)."""
import json,sys,re,statistics as st,collections
arms=collections.OrderedDict()
for a in sys.argv[1:]:
    name,d=a.split("=",1); pts=collections.defaultdict(list)
    for l in open(d+"/bench/points.jsonl"):
        if not l.startswith("{"): continue
        r=json.loads(l)
        if r.get("phase")=="fill": continue
        pts[re.sub(r"_r\d+$","",r["label"])].append(r)
    arms.setdefault(name,collections.defaultdict(list))
    for k,v in pts.items(): arms[name][k]+=v
order=[]
for a in arms.values():
    for k in a:
        if k not in order: order.append(k)
def cell(rs,key,scale=1,nd=1):
    v=[r[key]*scale for r in rs if r.get(key) is not None]
    if not v: return "-"
    return f"{'/'.join(f'{x:.{nd}f}' for x in v)} (mean {st.mean(v):.{nd}f})" if len(v)>1 else f"{v[0]:.{nd}f}"
names=list(arms)
print("| Point | "+" | ".join(f"Hit % {n}" for n in names)+" | "+" | ".join(f"TTFT p50 s {n}" for n in names)+" | "+" | ".join(f"Total tok/s {n} (mean)" for n in names)+" |")
print("|---|"+"---|"*(3*len(names)))
for k in order:
    row=[k.replace("_ret"," return").replace("_"," ")]
    row+=[cell(arms[n].get(k,[]),"prefill_hit",100) for n in names]
    row+=[cell(arms[n].get(k,[]),"ttft_p50") for n in names]
    row+=[(f"{st.mean([r['total_tok_s'] for r in arms[n][k] if r.get('total_tok_s')]):,.0f}" if arms[n].get(k) else "-") for n in names]
    print("| "+" | ".join(row)+" |")
