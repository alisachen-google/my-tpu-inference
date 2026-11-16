#!/usr/bin/env bash
# ws2_collect.sh <job-id>: pull outputs, print the return/static points, verify owner, delete the job.
export PATH="$HOME/bin:$PATH" KUBECONFIG="$HOME/.config/cdk/kubeconfig" CDK_ROOT_DIR="$HOME/cloud-devkit" CDK_DATA_DIR="$HOME/cloud-devkit-data"
J=$1; /mnt/disks/scratch/alisachen/tmp/gcs_pull.sh $J 2>&1 | tail -1
D=/mnt/disks/scratch/alisachen/cloud-devkit-data/job-outputs/$J/pd1992
python3 - "$D" <<'PY'
import json,sys,glob,os
D=sys.argv[1]
for l in open(D+"/bench/points.jsonl"):
    if not l.startswith("{"): continue
    r=json.loads(l)
    if r.get("phase")=="fill": continue
    t=r.get("client_cached_by_tier") or {}
    print(f"{r['run']:22s} {r['label']:18s} hit {100*r['prefill_hit']:5.1f}% ttft p50 {r['ttft_p50']:5.1f} p95 {r['ttft_p95']:5.1f} tok/s {r.get('total_tok_s') or 0:8.0f} warm {r.get('warm_sessions')}/{r['requests']} err {r['errors']} dev/host {t.get('device',0)/1e6:.2f}M/{t.get('host',0)/1e6:.2f}M")
for p in glob.glob(D+"/bench/*integrity.summary.json"):
    d=json.load(open(p)); rr=d["recall_vs_recompute"]; print("integrity exact", rr["exact"], "/", rr["compared"])
PY
for e in $D/prefill-0 $D/decode-0; do printf "%s: declined-drops %s exceptions %s; " $(basename $e) "$(grep -c 'subtree drop declined' $e/server.log)" "$(grep -c -E 'Scheduler hit an exception|out of memory' $e/server.log)"; grep "TP0 EP0\] \[dram-offload\] \(push\|recall\|landing\)" $e/server.log | tail -2 | sed -E 's/^\[[^]]*\] \[dram-offload\] //' | tr '\n' ';'; echo; done
U=$(cdkx job desc $J --no-color 2>/dev/null | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['user'])"); [ "$U" = alisachen_google_com ] && cdkx job delete $J 2>&1 | tail -1
