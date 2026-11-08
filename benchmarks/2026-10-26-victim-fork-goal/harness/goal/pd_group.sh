#!/usr/bin/env bash
# P/D group driver for any number of prefills and decodes, one TP-8 engine per host (same layout as pd_main.sh).
#   PREFILL_IPS="a b" DECODE_IPS="v7" pd_group.sh start <recipe.json> <RUN> | stop | status | stop-host <ip> | start-host <ip> <recipe> <RUN>
# Ranks: prefills first in list order, then decodes; rank 0 starts the LB. The recipe's group must match the counts.
set -uo pipefail
ME=alisachen_google_com; SERVER_PORT=30000; LB_PORT=${LB_PORT:-8080}
PREFILL_IPS=${PREFILL_IPS:?}; DECODE_IPS=${DECODE_IPS:?}
MYIP=$(hostname -I | awk '{print $1}')
SSH="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20"
ALL=($PREFILL_IPS $DECODE_IPS); NP=$(wc -w <<< "$PREFILL_IPS"); HOSTS=$(IFS=,; echo "${ALL[*]}")
P0=${ALL[0]}; D0=$(awk '{print $1}' <<< "$DECODE_IPS")
log() { echo "$(date -u '+%F %T') $*"; }
run_on() { if [[ $1 == "$MYIP" ]]; then bash -lc "$2"; else $SSH sa_101411256518727260534@$1 "sudo -n -iu $ME bash -lc $(printf %q "$2")"; fi; }
rank_of() { for i in "${!ALL[@]}"; do [[ ${ALL[$i]} == "$1" ]] && { echo $i; return; }; done; echo "unknown host $1" >&2; exit 2; }
role_of() { (( $(rank_of "$1") < NP )) && echo prefill || echo decode; }
spawn() { # ip recipe run
  local ip=$1 recipe=$2 run=$3 rank role; rank=$(rank_of "$ip"); role=$(role_of "$ip")
  run_on "$ip" "mkdir -p /home/$ME/pd_disagg/results/runs/$run && cd /tmp && exec >/dev/null 2>&1 </dev/null; SGLANG_ROOT=/home/$ME/sglang-main PYTHON=/home/$ME/venv/sglang-main/bin/python PREFILL_IP=$P0 DECODE_IP=$D0 LAUNCHER_HOSTNAMES=$HOSTS LAUNCHER_RANK=$rank LAUNCHER_HOST_IP=$ip ENABLE_COMPILE_CACHE=1 setsid nohup bash /home/$ME/pd_disagg/scripts/launch_role.sh $recipe $role $run >> /home/$ME/pd_disagg/results/runs/$run/launcher_${role}_$ip.out 2>&1 </dev/null & echo \$!"
}
wait_url() { local deadline=$(( $(date +%s) + $2 )); local t0=$(date +%s)
  while (( $(date +%s) < deadline )); do if curl -sf -m 5 "$1" >/dev/null 2>&1; then log "$3 ready after $(( $(date +%s) - t0 )) s"; return 0; fi; sleep 20; done
  log "$3 NOT ready after $2 s"; return 1; }
case "${1:-}" in
start) recipe=${2:?}; run=${3:?}
  for ip in $DECODE_IPS $PREFILL_IPS; do log "$(role_of $ip) rank $(rank_of $ip) on $ip"; spawn "$ip" "$recipe" "$run"; done
  for ip in "${ALL[@]}"; do wait_url "http://$ip:$SERVER_PORT/health" 5400 "$(role_of $ip) $ip /health"; done
  wait_url "http://$P0:$LB_PORT/health" 900 "LB /health" ;;
start-host) ip=${2:?}; recipe=${3:?}; run=${4:?}; log "$(role_of $ip) rank $(rank_of $ip) on $ip"; spawn "$ip" "$recipe" "$run"; wait_url "http://$ip:$SERVER_PORT/health" 5400 "$(role_of $ip) $ip /health" ;;
stop-host) ip=${2:?}; log "stopping ours on $ip"; run_on "$ip" "bash /home/$ME/pd_disagg/scripts/cleanup.sh" ;;
stop) for ip in "${ALL[@]}"; do log "stopping ours on $ip"; run_on "$ip" "bash /home/$ME/pd_disagg/scripts/cleanup.sh"; done ;;
status) for ip in "${ALL[@]}"; do echo "== $ip ($(role_of $ip))"; run_on "$ip" "pgrep -u $ME -af 'launch_server|launch_router' | cut -c1-120 | head -3; echo sched=\$(pgrep -u $ME -fc 'sglang::scheduler')"; done
  for ip in "${ALL[@]}"; do printf 'http://%s:%s health=%s\n' $ip $SERVER_PORT "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://$ip:$SERVER_PORT/health)"; done; printf 'LB health=%s\n' "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://$P0:$LB_PORT/health)" ;;
*) echo "usage: start <recipe> <run> | stop | status | start-host <ip> <recipe> <run> | stop-host <ip>" >&2; exit 2 ;;
esac
