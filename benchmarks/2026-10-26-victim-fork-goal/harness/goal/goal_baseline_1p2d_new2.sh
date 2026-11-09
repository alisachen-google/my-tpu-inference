#!/usr/bin/env bash
# Switch-OFF arms of the multi-engine layouts (write-back, same workloads, seeds and routes as the switch-on stages), for the
# on-vs-off comparison: 1P2D (a -> v7 + b), 2P1D (a + b -> v7), 2P2D (a + b -> v7 + g). Runs after the 2P2D stage.
set -u
L=$HOME/pd_disagg/live; SP=$HOME/pd_disagg/spill; R=$SP/results_goal; A=10.128.0.246; V=10.128.0.175; B=10.128.15.239; G=10.128.0.175
PY=$HOME/venv/sglang/bin/python
QWEN=/mnt/data/tt/hf-cache/hub/models--Qwen--Qwen3-30B-A3B-Instruct-2507-FP8/snapshots/5a5a776300a41aaa681dd7ff0106608ef2bc90db
SSHO="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20"
SSHA="$SSHO sa_101411256518727260534@$A"
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
deploy_all() { ( cd $L; for ip in "$@"; do bash deploy_1992.sh $ip $HOME/sglang-1992 > deploy_$ip.log 2>&1 & done; wait ); for ip in "$@"; do grep -q DEPLOY_OK $L/deploy_$ip.log || { log "deploy of PR 1992 to $ip failed"; return 1; }; done; log "PR 1992 $(git -C $HOME/sglang-1992 rev-parse --short HEAD) deployed to: $*"; }
log() { echo "$(date -u '+%F %T') $*" >> $L/goal_followup.log; }
hc() { curl -s -m 10 -o /dev/null -w '%{http_code}' $1; }
flush_one() { for i in $(seq 1 30); do [ "$(curl -s -m 300 -o /dev/null -w '%{http_code}' -X POST $1/flush_cache)" = 200 ] && return 0; sleep 10; done; return 1; }
wipe() { for ip in $DEC $PRE; do flush_one http://$ip:30000 || return 1; done; }
free_all() { for ip in $PRE $DEC; do while true; do
    h=$($SSHO sa_101411256518727260534@$ip "sudo fuser -v /dev/vfio/0 2>&1 | awk 'NR>1{print \$(NF-3)}' | sort -u | grep -v alisachen | tr '\n' ' '" 2>/dev/null); rc=$?
    [ $rc -eq 0 ] && [ -z "$(echo $h | tr -d ' ')" ] && break; log "waiting for TPU on $ip (held by $h)"; sleep 120; done; done; }
recall() { # label sessions phase lb seed
  $PY $SP/victim_recall.py --sessions $2 --prefix 131072 --new 8192 --out-tokens 16 --concurrency 4 --seed ${5:-5} --run $RUN --phase $3 --settle 20 --label $1 --tokenizer $QWEN --lb $4 --out $R/${RUN}_$1.jsonl > $R/${RUN}_$1.out 2>&1
  $PY $L/strict.py $R/${RUN}_$1.jsonl; }
hits() { $PY - $R/${RUN}_$1.jsonl <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.startswith('{')]
rec=[r for r in rows if r.get('phase')=='recall' and r.get('reusable_tokens')]
if rec: print(f"recall-phase prefix hit {100*sum(r.get('cached_tokens') or 0 for r in rec)/sum(r['reusable_tokens'] for r in rec):.1f}% over {len(rec)} requests")
PY
}
lb() { # port prefill_ip decode_ip
  $SSHA "sudo systemd-run --unit=alisachen-lb-$1 --collect --uid=731364623 --gid=731364623 -E HOME=/home/alisachen_google_com --working-directory=/home/alisachen_google_com/sglang-main bash -c 'export SGLANG_ROOT=\$PWD PYTHONPATH=\$PWD/python:\$PWD/sgl-model-gateway/bindings/python/src:\$PWD; exec /home/alisachen_google_com/venv/sglang-main/bin/python -m sglang_router.launch_router --pd-disaggregation --mini-lb --prefill http://$2:30000 8998 --decode http://$3:30000 --host 0.0.0.0 --port $1 > /home/alisachen_google_com/pd_disagg/results/runs/$RUN/lb_$1.log 2>&1'" 2>&1 | tail -1; }
lbs_up() { for i in $(seq 1 30); do ok=1; for p in "$@"; do [ "$(hc http://$A:$p/health)" = 200 ] || ok=0; done; [ $ok = 1 ] && return 0; sleep 5; done; return 1; }
stop_all() { $SSHA "sudo systemctl stop 'alisachen-lb-*' 2>/dev/null; sudo pkill -u alisachen_google_com -f 'sglang_router.launch_route[r]'" > /dev/null 2>&1
  PREFILL_IPS="$PRE" DECODE_IPS="$DEC" bash $HOME/pd_disagg/scripts/pd_group.sh stop > /dev/null 2>&1; }
start_layout() { # name recipe
  mkdir -p $HOME/pd_disagg/results/runs/$RUN; free_all
  timeout 7200 env PREFILL_IPS="$PRE" DECODE_IPS="$DEC" bash $HOME/pd_disagg/scripts/pd_group.sh start $L/$2 $RUN > $SP/logs/${RUN}_start.log 2>&1
  h=""; for ip in $PRE $DEC; do h="$h $ip=$(hc http://$ip:30000/health)"; done; log "BASE $1 (switch off) $RUN started:$h lb=$(hc http://$A:8080/health)"; }


# ---- 1P2D off
deploy_all $A $V $B || exit 1
PRE="$A"; DEC="$V $B"; RUN=g1992b_1p2d_off_4; start_layout 1P2D pd_1992_qwen_wb_off_1p2d.json
lb 8081 $A $V; lb 8082 $A $B; lbs_up 8081 8082 || log "BASE 1P2D extra LBs not up"
wipe; ( recall w2_d1 8 both http://$A:8081 31 > $R/${RUN}_w2_d1.strict ) & p1=$!; recall w2_d2 8 both http://$A:8082 32 > $R/${RUN}_w2_d2.strict; wait $p1
log "BASE 1P2D sticky: decode1 $(cat $R/${RUN}_w2_d1.strict); $(hits w2_d1) | decode2 $(cat $R/${RUN}_w2_d2.strict); $(hits w2_d2)"
wipe; log "BASE 1P2D random: $(recall w1_recall 16 both http://$A:8080); $(hits w1_recall)"
stop_all

log "GOAL BASELINE 1P2D NEWHOSTS DONE"
