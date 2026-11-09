#!/usr/bin/env bash
# Shared-prefix stage on both trees (relaunch after the control-port bind failure on g), then the 2P2D wait.
L=$HOME/pd_disagg/live
bash $L/goal_shared_prefix.sh > $L/goal_shared_prefix.out 2>&1
sleep 60
bash $L/goal_2p2d_wait_nowait.sh > $L/goal_2p2d_wait.out 2>&1
