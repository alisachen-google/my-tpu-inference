#!/usr/bin/env bash
# Live validation of PR 1992 (tree deployed to ~/sglang-main, venv ~/venv/sglang-main) on a (prefill) + v7 (decode):
# Qwen3-30B, offload switch on, write_back then write_through; victim recall and static reuse points.
cd ~/pd_disagg/spill; echo $$ > logs/val_1992.pid
export TOK=/mnt/data/tt/hf-cache/hub/models--Qwen--Qwen3-30B-A3B-Instruct-2507-FP8/snapshots/5a5a776300a41aaa681dd7ff0106608ef2bc90db
export A_IP=10.128.15.217 B_IP=10.128.15.239 LAUNCHER=$HOME/pd_disagg/scripts/pd_main.sh CFG=after FLUSH_TRIES=15
export KINDS=${KINDS:-"recall static"} RECALL=${RECALL:-"131072:8192:12"} STATIC=${STATIC:-"131072:8192:12 131072:8192:16"}
for arm in ${ARMS:-wb wt}; do
  NAME=v${PR:-1992}_$arm RUN=v${PR:-1992}_${arm}_${TAG:-1} RECIPE=$HOME/pd_disagg/live/pd_1992_qwen_$arm.json bash chain_pair.sh > logs/goal_v${PR:-1992}_${arm}_${TAG:-1}.log 2>&1
  PREFILL_IP=$A_IP DECODE_IP=$B_IP bash $LAUNCHER stop > /dev/null 2>&1
  for i in 1 2 3 4 5 6; do sleep 5; done
done
echo "$(date -u '+%F %T') VAL 1992 DONE" >> logs/val_1992.log
