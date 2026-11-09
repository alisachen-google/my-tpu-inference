#!/usr/bin/env bash
# After the fix validation: stop the 2P2D wait that goal_tail7 starts, run the hybrid on/off sweep + edges on the new head, then resume the 2P2D wait.
L=$HOME/pd_disagg/live
until grep -q "GOAL FIXVAL DONE" $L/goal_followup.log; do sleep 60; done
sleep 90
for p in $(pgrep -f "goal_tail[7]\.sh") $(pgrep -f "goal_2p2d_wait_nowai[t]\.sh"); do kill $p 2>/dev/null; done
sleep 5
echo "$(date -u +%F\ %T) 2P2D wait paused for the hybrid on/off validation (goal_hybrid_full.sh)" >> $L/goal_followup.log
bash $L/goal_hybrid_full.sh > $L/goal_hybrid_full.out 2>&1
sleep 60
bash $L/goal_2p2d_wait_nowait.sh > $L/goal_2p2d_wait.out 2>&1
