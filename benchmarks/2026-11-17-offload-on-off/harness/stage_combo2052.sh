#!/usr/bin/env bash
# The PR 2052 evaluation in one job: the shared-prefix cases (stage_shared.sh, results under $OUT/shared), then the
# recall ladder and the static ladders (stage_static1789.sh, results under $OUT/ladders).
BASE_OUT=$OUT; rc=0
mkdir -p "$BASE_OUT/shared" "$BASE_OUT/ladders"
OUT="$BASE_OUT/shared" bash "$HARNESS/stage_shared.sh" || rc=$?
RECALL_POINTS="${RECALL_POINTS:-8 12 16}" OUT="$BASE_OUT/ladders" bash "$HARNESS/stage_static1789.sh" || rc=$?
exit $rc
