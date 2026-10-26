#!/usr/bin/env bash
# Queue on a+b after the main before sweep: before extras, before static, after recall, after static.
L=$HOME/pd_disagg/spill/logs
EXTRA="131072:8192:10 131072:8192:20 131072:8192:28 262144:16384:5 262144:16384:10 262144:16384:14"
FULL="131072:8192:8 131072:8192:10 131072:8192:12 131072:8192:16 131072:8192:20 131072:8192:24 131072:8192:28 131072:8192:32 262144:16384:4 262144:16384:5 262144:16384:6 262144:16384:8 262144:16384:10 262144:16384:12 262144:16384:14 262144:16384:16"
until grep -q 'ALL DONE' $L/chain_recall_before.log; do sleep 30; done
sleep 60
cd $HOME/pd_disagg/spill
CFGS=before POINTS="$EXTRA" bash chain_recall.sh > $L/chain_recall_before_extra.log 2>&1; sleep 60
CFGS=before bash chain_static_reuse.sh > $L/chain_static_reuse_before.log 2>&1; sleep 60
CFGS=after SGLANG_TPU_DEBUG_VICTIM_CRC=0 POINTS="$FULL" bash chain_recall.sh > $L/chain_recall_after_ab.log 2>&1; sleep 60
CFGS=after SGLANG_TPU_DEBUG_VICTIM_CRC=0 bash chain_static_reuse.sh > $L/chain_static_reuse_after.log 2>&1
echo "QUEUE DONE $(date -u '+%F %T')"
