#!/usr/bin/env bash
# After the rough post-simplification check: rerun the one-at-a-time shared-prefix case with the extended fix, then resume the 2P2D wait.
L=$HOME/pd_disagg/live
until grep -q "GOAL SIMPL DONE\|SIMPL deploy of" $L/goal_followup.log && [ -f $L/sharedfix2_ready ]; do sleep 60; done
sleep 60
for p in $(pgrep -f "goal_tail1[2]\.sh") $(pgrep -f "goal_2p2d_wait_nowai[t]\.sh"); do kill $p 2>/dev/null; done
sleep 5
echo "$(date -u +%F\ %T) 2P2D wait paused for the shared-prefix rerun (goal_shared_fix2.sh)" >> $L/goal_followup.log
bash $L/goal_shared_fix2.sh > $L/goal_shared_fix2.out 2>&1
sleep 60
echo "$(date -u +%F\ %T) 2P2D wait resumed" >> $L/goal_followup.log
bash $L/goal_2p2d_wait_nowait.sh > $L/goal_2p2d_wait.out 2>&1
