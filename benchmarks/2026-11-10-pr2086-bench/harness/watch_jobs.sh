#!/usr/bin/env bash
# watch_jobs.sh <job-id> ... : emits job status transitions, startup milestones, stage lines and engine errors.
export PATH="$HOME/bin:$PATH" KUBECONFIG="$HOME/.config/cdk/kubeconfig" CDK_ROOT_DIR="$HOME/cloud-devkit" CDK_DATA_DIR="$HOME/cloud-devkit-data"
NS=cloud-devkit-jobs; declare -A prev
while true; do
  list=$(cdkx job list -o json 2>/dev/null || echo '[]'); alive=0
  for JS in "$@"; do
    cur=$(python3 -c 'import json,sys
for j in json.load(sys.stdin):
    if j["id"]==sys.argv[1]: print(j.get("job_status"), j.get("state"))' "$JS" <<<"$list" 2>/dev/null || true)
    [ -n "$cur" ] && [ "$cur" != "${prev[$JS]:-}" ] && { echo "[$JS job] $cur"; prev[$JS]=$cur; }
    case "$cur" in *Succeeded*|*Failed*|*Deleted*|*InitFailed*|*Complete*) continue;; esac; alive=$((alive+1))
    SEEN=/mnt/disks/scratch/alisachen/tmp/seen_$JS.txt; touch "$SEEN"
    pods=$(kubectl get pods -n $NS -l jobset.sigs.k8s.io/jobset-name=$JS -o custom-columns='N:.metadata.name,P:.status.phase' --no-headers 2>/dev/null || true)
    for role in bench prefill-0 prefill-1 decode-0 decode-1; do
      pod=$(awk -v r="$JS-$role" '$1 ~ "^"r"-" {print $1; exit}' <<<"$pods"); [ -n "$pod" ] || continue
      if [ "$role" = bench ]; then pat='^[0-9-]+ [0-9:]+ (LAYOUT|1P1D|1P2D|2P1D|2P2D|A1|E[1-3]|EDGES|SMOKE|BENCH|TRANSITIONS|T[1-4]_|chain|random|recall [0-9]+|static [0-9]+|mixed|integrity|  =>|cycle [0-9]+ level [0-9]+ conc|cycle [0-9]+: verify|GSM8K baseline acc|health probe|STRESS )|FAIL|Gave up|stage [a-z0-9_]+ rc|Traceback'; else pat='Scheduler hit an exception|UnsupportedDramOffloadConfig|out of memory|ImportError|server exited rc|The server is fired up|FAIL:|RuntimeError|Segmentation'; fi
      kubectl logs -n $NS "$pod" --tail=300 2>/dev/null | grep -E "$pat" | grep -v 'Ignore import error' | cut -c1-230 | while IFS= read -r l; do
        key=$(printf '%s' "$role|$l" | md5sum | cut -c1-16)
        grep -q "$key" "$SEEN" || { echo "$key" >> "$SEEN"; echo "[${JS:0:10} $role] $l"; }
      done
    done
  done
  [ "$alive" = 0 ] && { echo "[watch] all jobs terminal"; exit 0; }
  sleep 90
done
