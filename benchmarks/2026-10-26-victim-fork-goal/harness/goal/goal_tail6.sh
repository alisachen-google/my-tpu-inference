#!/usr/bin/env bash
# Hybrid accumulation run on g+v7, then 2P2D (on + off) when a fourth host is usable.
L=$HOME/pd_disagg/live
bash $L/goal_hybrid_accum.sh > $L/goal_hybrid_accum.out 2>&1
sleep 60
bash $L/goal_2p2d_wait_nowait.sh > $L/goal_2p2d_wait.out 2>&1
