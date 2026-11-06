#!/usr/bin/env bash
# One static point on the write-back + switch recipe, on the diag-instrumented tree. Leaves the pair up.
cd ~/pd_disagg/spill; echo $$ > logs/static_wb_diag.pid; RC=$HOME/pd_disagg/recipes/v6c_long/victim
export A_IP=${A_IP:-10.128.15.217} B_IP=${B_IP:-10.128.0.90} LAUNCHER=$PWD/pd_pr_vw.sh CFG=after KINDS=static FLUSH_TRIES=15
RUN=${RUN:-swb_diag_1} NAME=swb_diag RECIPE=${RECIPE:-$RC/gpt-oss_C_static_wb_spill.json} STATIC=${STATIC:-"131072:8192:12"} bash chain_pair.sh > logs/goal_${RUN:-swb_diag_1}.log 2>&1
echo "$(date -u '+%F %T') DIAG DONE" >> logs/static_wb_diag.log
