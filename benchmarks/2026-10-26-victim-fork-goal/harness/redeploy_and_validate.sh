#!/usr/bin/env bash
# Sync the worktree to both hosts (a prefill, v7 decode), then run the live validation arms.
cd ~/pd_disagg/live
bash deploy_1992.sh 10.128.15.217 ${TREE:?} > deploy_a.log 2>&1 &
bash deploy_1992.sh 10.128.15.239 ${TREE:?} > deploy_v7.log 2>&1
wait
grep -q DEPLOY_OK deploy_a.log && grep -q DEPLOY_OK deploy_v7.log || { echo "deploy failed"; tail -5 deploy_a.log deploy_v7.log; exit 1; }
echo "$(date -u '+%F %T') deployed; starting validation (ARMS=${ARMS:-wb wt} TAG=${TAG:-1})"
bash ~/pd_disagg/live/val_1992.sh
