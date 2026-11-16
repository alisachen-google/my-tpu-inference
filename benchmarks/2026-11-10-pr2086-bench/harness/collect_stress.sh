#!/usr/bin/env bash
# collect_stress.sh <job-id>: every 5 min, copy the bench pod's open stress files (gcsfuse publishes them only on
# close) to the VM and sample pod memory with kubectl top; stops when the job's pods are gone.
export PATH="$HOME/bin:$PATH" KUBECONFIG="$HOME/.config/cdk/kubeconfig" CDK_ROOT_DIR="$HOME/cloud-devkit" CDK_DATA_DIR="$HOME/cloud-devkit-data"
J=$1; NS=cloud-devkit-jobs; DEST=/mnt/disks/scratch/alisachen/tmp/stress_live/$J; mkdir -p "$DEST"
while true; do
  B=$(kubectl get pods -n $NS -l jobset.sigs.k8s.io/jobset-name=$J -o name 2>/dev/null | grep bench | head -1)
  if [ -z "$B" ]; then
    # between a preemption and its retry there is no pod; stop only when cdk says the job is over
    st=$(cdkx job list -o json 2>/dev/null | python3 -c "import json,sys; print([j['job_status'] for j in json.load(sys.stdin) if j['id']=='$J'][0])" 2>/dev/null)
    case "$st" in Succeeded|Failed|Deleted) echo "$(date -u +%FT%TZ) job $st, no pod; exit"; exit 0;; esac
    echo "$(date -u +%FT%TZ) no bench pod (job $st); waiting"; sleep 120; continue
  fi
  ph=$(kubectl get -n $NS $B -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$ph" = Running ]; then
    kubectl exec -n $NS ${B#pod/} -c bench -- bash -c 'cd /cdk-outputs/pd1992/bench 2>/dev/null && tar c $(ls | grep -E "_stress" ) stage.log 2>/dev/null' 2>/dev/null | tar x -C "$DEST" 2>/dev/null && echo "$(date -u +%FT%TZ) synced $(ls $DEST | wc -l) files"
  fi
  kubectl top pods -n $NS -l jobset.sigs.k8s.io/jobset-name=$J --containers --no-headers 2>/dev/null | awk -v t="$(date -u +%FT%TZ)" '{print t, $1, $2, $3, $4}' >> "$DEST/mem.log"
  case "$ph" in Succeeded|Failed) echo "$(date -u +%FT%TZ) bench $ph; final sync done; exit"; exit 0;; esac
  sleep 300
done
