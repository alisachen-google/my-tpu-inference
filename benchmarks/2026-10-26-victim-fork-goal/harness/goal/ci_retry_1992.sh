#!/usr/bin/env bash
# Re-run the lint (42580323893) and gitleaks (42580323991) jobs of PR 1992 head 4b3de649ff while they fail only on a
# GitHub release download error (curl exit 22 / HTTP 504), every 20 minutes, at most 10 times; once lint is green,
# re-run the failed CPU shards (42580324009) once. Logs to goal_followup.log as "CI1992 ...".
L=$HOME/pd_disagg/live; TOKEN=$(sed -n 's#.*://[^:]*:\([^@]*\)@.*#\1#p' ~/.git-credentials | head -1)
API=https://api.github.com/repos/sgl-project/sglang-torchtpu
log() { echo "$(date -u '+%F %T') CI1992 $*" >> $L/goal_followup.log; }
run_state() { curl -s -H "Authorization: token $TOKEN" "$API/actions/runs/$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['status'], d['conclusion'], d['run_attempt'])"; }
download_error() { # run id -> 0 if the latest failed job of the run died on a download (exit code 22)
  curl -s -H "Authorization: token $TOKEN" "$API/actions/runs/$1/jobs?per_page=50" | python3 -c "import json,sys; print(' '.join(str(j['id']) for j in json.load(sys.stdin)['jobs'] if j['conclusion']=='failure'))" | tr ' ' '\n' | while read j; do [ -n "$j" ] && curl -s -L -H "Authorization: token $TOKEN" "$API/actions/jobs/$j/logs" | grep -q "Process completed with exit code 22" && echo yes; done | grep -q yes; }
rerun() { curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: token $TOKEN" "$API/actions/runs/$1/rerun-failed-jobs"; }
cpu_rerun_done=0
for attempt in $(seq 1 10); do
  for r in 42580323893 42580323991; do
    read status conclusion n <<< "$(run_state $r)"
    if [ "$status" = completed ] && [ "$conclusion" = failure ]; then
      if download_error $r; then log "run $r attempt $n failed on a release download; re-running (try $attempt): http $(rerun $r)"; else log "run $r attempt $n failed for another reason; leaving it"; fi
    fi
  done
  read status conclusion n <<< "$(run_state 42580323893)"
  if [ "$status" = completed ] && [ "$conclusion" = success ] && [ $cpu_rerun_done = 0 ]; then
    log "lint green (attempt $n); re-running the failed CPU shards: http $(rerun 42580324009)"; cpu_rerun_done=1
  fi
  read s2 c2 n2 <<< "$(run_state 42580323991)"
  if [ $cpu_rerun_done = 1 ] && [ "$c2" = success ]; then log "lint and gitleaks green; done"; exit 0; fi
  sleep 1200
done
log "gave up after 10 tries; lint=$(run_state 42580323893) gitleaks=$(run_state 42580323991)"
