#!/usr/bin/env bash
# After the shared-prefix fix validation and once the simplified 1992 tree is folded (flag file), run the rough check, then resume the 2P2D wait.
L=$HOME/pd_disagg/live
until grep -q "GOAL SHAREDFIX DONE\|SHAREDFIX deploy of the fix tree failed" $L/goal_followup.log && [ -f $L/simplified_ready ]; do sleep 60; done
sleep 30
bash $L/goal_simplified_check.sh > $L/goal_simplified_check.out 2>&1
sleep 60
echo "$(date -u +%F\ %T) 2P2D wait resumed" >> $L/goal_followup.log
bash $L/goal_2p2d_wait_nowait.sh > $L/goal_2p2d_wait.out 2>&1
