#!/usr/bin/env bash
# After the shared-prefix rerun: rough live check of the round-2 head, then resume the 2P2D wait.
L=$HOME/pd_disagg/live
until grep -q "GOAL SHAREDFIX2 DONE\|SHAREDFIX2 deploy of" $L/goal_followup.log; do sleep 60; done
sleep 60
for p in $(pgrep -f "goal_tail1[3]\.sh") $(pgrep -f "goal_2p2d_wait_nowai[t]\.sh"); do kill $p 2>/dev/null; done
sleep 5
echo "$(date -u +%F\ %T) 2P2D wait paused for the round-2 live check (goal_simplified_check2.sh)" >> $L/goal_followup.log
bash $L/goal_simplified_check2.sh > $L/goal_simplified_check2.out 2>&1
sleep 60
echo "$(date -u +%F\ %T) 2P2D wait resumed" >> $L/goal_followup.log
bash $L/goal_2p2d_wait_nowait.sh > $L/goal_2p2d_wait.out 2>&1
