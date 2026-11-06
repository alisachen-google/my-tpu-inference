#!/usr/bin/env bash
# Static prefix-reuse (K docs x 3 visits) on a 1P/1D pair, two arms on the same tree: write-back only, then
# write-back + offload switch. Prefill + LB on A_IP, decode on B_IP.
cd ~/pd_disagg/spill; echo $$ > logs/static_wb_queue.pid; RC=$HOME/pd_disagg/recipes/v6c_long/victim
export A_IP=${A_IP:-10.128.15.239} B_IP=${B_IP:-10.128.0.90} LAUNCHER=$PWD/pd_pr_vw.sh CFG=after KINDS=static FLUSH_TRIES=15
for arm in ${ARMS:-off spill}; do
  NAME=swb_$arm RUN=swb_${arm}_1 RECIPE=$RC/gpt-oss_C_static_wb_$arm.json bash chain_pair.sh > logs/goal_swb_${arm}_1.log 2>&1
  PREFILL_IP=$A_IP DECODE_IP=$B_IP bash pd_pr_vw.sh stop > /dev/null 2>&1; sleep 30
done
echo "$(date -u '+%F %T') STATIC WB QUEUE DONE" >> logs/static_wb_queue.log
