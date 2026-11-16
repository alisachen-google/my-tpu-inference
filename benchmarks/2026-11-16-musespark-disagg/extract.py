#!/usr/bin/env python3
"""Extract every job of dash d-19d6aedd-af5d-481d-9929 (sheet tags) with its result metrics and submit command."""
import json, subprocess, sys, yaml, os
from concurrent.futures import ThreadPoolExecutor
SHEETS = """musespark-gb300-trt-fp4-mn-offload-radixark-dflash2-tp4ep4-agentx-oct27-4gpus
musespark-vr200-dynamo-trt-fp4-mn-offload-radixark-dflash2-tp4ep4-agentx-nov03-4gpus
musespark-vr200-dynamo-trt-fp4-mn-offload-radixark-dflash2-tp8ep8-agentx-nov03-8gpus
musespark-vr200-dynamo-trt-fp4-disagg-offload-radixark-dflash2-d4xtp4ep4-agentx-nov03-20gpus
musespark-vr200-dynamo-trt-fp4-disagg-offload-radixark-dflash2-d5xtp4ep4-agentx-nov03-24gpus
musespark-vr200-dynamo-trt-fp4-disagg-offload-radixark-dflash2-d7xtp4ep4-agentx-nov03-32gpus
musespark-vr200-dynamo-trt-fp4-disagg-offload-radixark-dflash2-d4xtp8ep8-agentx-nov03-36gpus
junyanxu-agentx-muse-v11-mk1909-wave5
musespark-tpu7x-sglang-pd-pp8tp8-agentx-8chips
junyanxu-agentx-muse-q4mk-exp-sweep
junyanxu-agentx-muse-q4mk-exp-best
junyanxu-agentx-muse-q4mk-fixed-sweep
junyanxu-agentx-muse-q4mk-launchcut-sweep
musespark-vr200-nov03-curve""".split()
env = dict(os.environ)
def sh(args):
    return subprocess.run([os.path.expanduser("~/bin/cdkx")] + args, capture_output=True, text=True, env=env).stdout
def flat(v):
    if isinstance(v, list) and v and isinstance(v[0], dict) and "key" in v[0]:
        return {i["key"]: flat(i["value"]) for i in v}
    return v
def desc(jid):
    d = yaml.safe_load(sh(["job", "desc", jid, "--no-color"]))
    return {"id": jid, "user": d.get("user"), "recipe": d.get("recipe"), "tags": d.get("tags"), "create_time": str(d.get("create_time")),
            "job_status": d.get("job_status"), "cmd": d.get("cmd"), "result": flat(d.get("result") or [])}
rows = {}
sheet_jobs = {}
for s in SHEETS:
    try:
        jobs = json.loads(sh(["job", "list", "-a", "-H", "-n", "300", "-t", s, "-o", "json"]) or "[]")
    except Exception as e:
        jobs = []
    sheet_jobs[s] = [j["id"] for j in jobs]
ids = sorted({i for v in sheet_jobs.values() for i in v})
with ThreadPoolExecutor(8) as ex:
    for r in ex.map(desc, ids):
        rows[r["id"]] = r
json.dump({"sheets": sheet_jobs, "jobs": rows}, open("dash_data.json", "w"), indent=1, default=str)
print({s: len(v) for s, v in sheet_jobs.items()}, "total", len(ids))
