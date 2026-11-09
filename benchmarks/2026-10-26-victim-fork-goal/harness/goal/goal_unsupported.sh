#!/usr/bin/env bash
# Unsupported configurations with the switch on must fail explicitly at engine start: the engine names the setting,
# exits, never reaches /health, and leaves no process or port behind. One engine at a time on host H (PR 1992 tree).
#   UNSUP <case>: REFUSED (<reason>) exit=<s> port_free=<yes|no>   -- the expected outcome
#   UNSUP <case>: SILENT (health 200)                               -- a silent acceptance: a defect
#   UNSUP <case>: OTHER_FAILURE (<first error line>)                -- failed before the check, explicit but unnamed
#   UNSUP <case>: HUNG                                              -- neither refused nor healthy nor exited in time
set -u
L=$HOME/pd_disagg/live; SP=$HOME/pd_disagg/spill; R=$SP/results_goal; H=${UNSUP_HOST:-10.128.0.246}
SSHO="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20"
SSHH="$SSHO sa_101411256518727260534@$H"
RUNS=/home/alisachen_google_com/pd_disagg/results/runs
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
log() { echo "$(date -u '+%F %T') $*" >> $L/goal_followup.log; }
PM() { PREFILL_IP=$H DECODE_IP=$H bash $HOME/pd_disagg/scripts/pd_main.sh "$@"; }
remote_procs() { $SSHH "pgrep -u alisachen_google_com -fc 'launch_server|sglang::'" 2>/dev/null | tail -1; }
port_free() { $SSHH "ss -ltn 2>/dev/null | grep -q ':30000 ' && echo no || echo yes" 2>/dev/null | tail -1; }
server_log() { $SSHH "sudo cat $RUNS/$1/$2/server.log 2>/dev/null" 2>/dev/null; }

variant() { # case role python-patch -> writes $L/unsup_<case>.json locally and on H
  local name=$1 role=$2 patch=$3
  python3 - "$L/pd_1992_qwen_wb.json" "$L/unsup_$name.json" "$role" "$patch" <<'EOF'
import json, sys
src, dst, role, patch = sys.argv[1:5]
r = json.load(open(src))
sa = r[role]["server_args"]; env = r["runtime_envs"]
exec(patch)  # operates on sa (server_args of the role) and env (runtime_envs)
json.dump(r, open(dst, "w"), indent=1)
EOF
  rsync -a -e "$SSHO" --rsync-path='sudo rsync' "$L/unsup_$name.json" sa_101411256518727260534@$H:$L/unsup_$name.json
}

run_case() { # case role
  local name=$1 role=$2 run=unsup_$1 t0 verdict reason exit_s="" pf
  $SSHH "sudo rm -rf $RUNS/$run" 2>/dev/null
  t0=$(date +%s)
  ( timeout 1500 env PREFILL_IP=$H DECODE_IP=$H bash $HOME/pd_disagg/scripts/pd_main.sh start-$role $L/unsup_$name.json $run > $SP/logs/${run}_start.log 2>&1 ) &
  local starter=$!
  verdict=""; reason=""
  while (( $(date +%s) - t0 < 1500 )); do
    sleep 15
    local lg; lg=$(server_log $run $role)
    if echo "$lg" | grep -q "is not supported on this $role engine"; then
      verdict=REFUSED; reason=$(echo "$lg" | grep -m1 -o "is not supported on this $role engine: .*" | cut -c1-260); break
    fi
    if [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://$H:30000/health)" = 200 ]; then verdict=SILENT; break; fi
    if echo "$lg" | grep -q "An engine or router exited"; then
      verdict=OTHER_FAILURE; reason=$(echo "$lg" | grep -m1 -E "Error|error:|Exception|not supported|Unsupported|invalid|Invalid" | cut -c1-260); break
    fi
  done
  [ -z "$verdict" ] && verdict=HUNG
  if [ $verdict = REFUSED ] || [ $verdict = OTHER_FAILURE ]; then
    local t1=$(date +%s)
    while (( $(date +%s) - t1 < 180 )); do [ "$(remote_procs)" = 0 ] && break; sleep 10; done
    exit_s=$(( $(date +%s) - t1 )); [ "$(remote_procs)" = 0 ] || exit_s="NOT-EXITED"
  fi
  kill $starter 2>/dev/null; wait $starter 2>/dev/null
  PM stop-$role > /dev/null 2>&1
  pf=$(port_free)
  log "UNSUP $name ($role): $verdict ${reason:+(}${reason}${reason:+)} exit_after_s=${exit_s:-n/a} port_free=$pf total_s=$(( $(date +%s) - t0 ))"
  echo "$lg" | grep -i "not supported\|error\|exited" | head -12 | cut -c1-300 > $R/${run}_lines.txt 2>/dev/null
}

( cd $L; bash deploy_1992.sh $H $HOME/sglang-1992 > deploy_unsup.log 2>&1 ) ; grep -q DEPLOY_OK $L/deploy_unsup.log || { log "UNSUP deploy of PR 1992 to $H failed"; exit 1; }
PM stop > /dev/null 2>&1
log "UNSUP sweep on $H with PR 1992 $(git -C $HOME/sglang-1992 rev-parse --short HEAD): one engine per unsupported setting, switch on"

variant radix_off        prefill 'sa["disable_radix_cache"] = True'
variant optimistic       prefill 'sa["optimistic_prefill_attempts"] = 1'
variant hicache_off      prefill 'sa["enable_hierarchical_cache"] = False; [sa.pop(k, None) for k in ("hicache_ratio", "hicache_io_backend", "hicache_mem_layout", "hicache_write_policy")]'
variant io_kernel        prefill 'sa["hicache_io_backend"] = "kernel"'
variant l3_file          prefill 'sa["hicache_storage_backend"] = "file"'
variant unified_mem      prefill 'sa["enable_unified_memory"] = True'
variant pipeline_env     prefill 'env["SGLANG_RAIDEN_PIPELINE_TRANSFER"] = "1"'
variant transfer_mooncake prefill 'sa["disaggregation_transfer_backend"] = "mooncake"'
variant spec_ngram       prefill 'sa["speculative_algorithm"] = "NGRAM"; sa["speculative_num_draft_tokens"] = 4'
variant sleep_idle       decode  'sa["sleep_on_idle"] = True'
variant decode_no_radix  decode  'sa["disaggregation_decode_enable_radix_cache"] = False'
variant pp2              prefill 'sa["pp_size"] = 2; sa["tp_size"] = 4; sa["ep_size"] = 4'
variant dp2              prefill 'sa["dp_size"] = 2; sa["tp_size"] = 4; sa["ep_size"] = 4'

for spec in "radix_off prefill" "optimistic prefill" "hicache_off prefill" "io_kernel prefill" "l3_file prefill" "unified_mem prefill" \
            "pipeline_env prefill" "transfer_mooncake prefill" "spec_ngram prefill" "sleep_idle decode" "decode_no_radix decode" \
            "pp2 prefill" "dp2 prefill"; do
  set -- $spec; run_case $1 $2
done
log "GOAL UNSUPPORTED DONE"
