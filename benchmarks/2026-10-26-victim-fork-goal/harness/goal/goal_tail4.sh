#!/usr/bin/env bash
# After NEWHOSTS2: the pressure-driven cross-prefill case (X2b), then the hybrid reproduction on g+v7 (F1D), then 2P2D when a fourth host is usable.
L=$HOME/pd_disagg/live
until grep -q "GOAL NEWHOSTS2 DONE" $L/goal_followup.log; do sleep 60; done
sleep 60
bash $L/goal_2p1d_x2b.sh > $L/goal_2p1d_x2b.out 2>&1
sleep 60
echo "$(date -u +%F\ %T) F1D (second attempt, fixed hook): full hybrid sequence on g + v7" >> $L/goal_followup.log
STEPS="F1D" bash $L/goal_hybrid_dbg_g.sh > $L/goal_hybrid_dbg_g.out 2>&1
sleep 60

bash $L/goal_2p2d_wait_nowait.sh > $L/goal_2p2d_wait.out 2>&1
