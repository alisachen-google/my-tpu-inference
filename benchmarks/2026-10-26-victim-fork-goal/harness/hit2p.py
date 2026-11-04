import re, json, sys
from datetime import datetime, timedelta
d=sys.argv[1]
s=json.loads(open(f"{d}/client.jsonl").read().strip().split("\n")[-1])["summary"]
t0=datetime.strptime(s["start_local"], "%Y-%m-%d %H:%M:%S"); t1=t0+timedelta(seconds=s["duration_s"])
tot={"new":0,"device":0,"host":0}; per=[dict(new=0,device=0,host=0) for _ in range(6)]; perrank=[]
for r in (0,1):
    rt={"new":0,"device":0,"host":0}
    for line in open(f"{d}/server_r{r}_prefill.log", errors="replace"):
        m=re.match(r"\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) TP0[ \]]", line)
        if not m or "Prefill batch" not in line: continue
        t=datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")
        if not (t0 <= t < t1): continue
        v={k:int(re.search(rf"#{f}: (\d+)", line).group(1)) for k,f in (("new","new-token"),("device","hbm-hit-token"),("host","host-hit-token"))}
        b=int((t-t0).total_seconds()//600)
        for k in v: tot[k]+=v[k]; per[b][k]+=v[k]; rt[k]+=v[k]
    perrank.append(rt)
hit=lambda x: 100*(x["device"]+x["host"])/max(1,sum(x.values()))
n=sum(tot.values()); L=s["latency_s"]["main"]
print(f"| {s['label']} | {s['requests']} | {s['errors']} | {hit(tot):.1f} | {100*tot['device']/n:.1f} / {100*tot['host']/n:.1f} / {100*tot['new']/n:.1f} | {', '.join(f'{hit(p):.1f}' for p in per)} | {hit(perrank[0]):.1f} / {hit(perrank[1]):.1f} | {L['p50']} / {L['p90']} / {L['p99']} |")
