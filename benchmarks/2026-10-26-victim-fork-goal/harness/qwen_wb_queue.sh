#!/usr/bin/env bash
# Qwen3-30B (full attention) static prefix reuse on a 1P/1D pair, PR 1789 old-base tree: write-back only, then
# write-back + offload switch. Context 262144, so only the 128k ladder fits.
cd ~/pd_disagg/spill; echo $$ > logs/qwen_wb_queue.pid; RC=$HOME/pd_disagg/recipes/dense/victim
export TOK=/mnt/data/tt/hf-cache/hub/models--Qwen--Qwen3-30B-A3B-Instruct-2507-FP8/snapshots/5a5a776300a41aaa681dd7ff0106608ef2bc90db
export A_IP=${A_IP:-10.128.15.217} B_IP=${B_IP:-10.128.0.90} LAUNCHER=$PWD/pd_pr_vw.sh CFG=after KINDS=static FLUSH_TRIES=15
export STATIC=${STATIC:-"131072:8192:4 131072:8192:8 131072:8192:12 131072:8192:16 131072:8192:20 131072:8192:24 131072:8192:28"}
for arm in ${ARMS:-off spill}; do
  NAME=qwb_$arm RUN=qwb_${arm}_1 RECIPE=$RC/qwen3-30b_C_static_wb_$arm.json bash chain_pair.sh > logs/goal_qwb_${arm}_1.log 2>&1
  PREFILL_IP=$A_IP DECODE_IP=$B_IP bash pd_pr_vw.sh stop > /dev/null 2>&1; sleep 30
done
echo "$(date -u '+%F %T') QWEN WB QUEUE DONE" >> logs/qwen_wb_queue.log
