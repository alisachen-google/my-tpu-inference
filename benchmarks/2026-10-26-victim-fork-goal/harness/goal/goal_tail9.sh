#!/usr/bin/env bash
# After the hybrid on/off validation: stop the 2P2D wait that goal_tail8 starts, run the shared-prefix stage on both trees, then resume the 2P2D wait.
L=$HOME/pd_disagg/live
until grep -q "GOAL HYBRID FULL DONE\|HYBRID FULL deploy of the hybrid tree failed" $L/goal_followup.log; do sleep 60; done
sleep 90
for p in $(pgrep -f "goal_tail[8]\.sh") $(pgrep -f "goal_2p2d_wait_nowai[t]\.sh"); do kill $p 2>/dev/null; done
sleep 5
echo "$(date -u +%F\ %T) 2P2D wait paused for the shared-prefix stage (goal_shared_prefix.sh)" >> $L/goal_followup.log
bash $L/goal_shared_prefix.sh > $L/goal_shared_prefix.out 2>&1
sleep 60
bash $L/goal_2p2d_wait_nowait.sh > $L/goal_2p2d_wait.out 2>&1
