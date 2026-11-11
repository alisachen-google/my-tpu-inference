#!/usr/bin/env bash
# stage_results.sh <job-id> <arm> [<subdir>]: file a pulled job's bench results and engine evidence into the results repo
# (results/<subdir>/<arm>, evidence/<subdir>/<arm>), after recomputing points_fixed.jsonl.
set -eo pipefail
J=$1; ARM=$2; SUB=${3:-h83198bc}
H=/mnt/disks/scratch/alisachen/pd2086-harness
D=/mnt/disks/scratch/alisachen/cloud-devkit-data/job-outputs/$J/pd1992
R=/mnt/disks/scratch/alisachen/my-tpu-inference/benchmarks/2026-11-10-pr2086-bench
RES=$R/results/$SUB/$ARM; EV=$R/evidence/$SUB/$ARM
PTS=""; if [ -f $D/bench/points.jsonl ]; then python3 $H/recompute_points.py $D/bench > /dev/null; PTS="--points $D/bench/points_fixed.jsonl"; fi
mkdir -p "$RES" "$EV"
for f in $D/bench/*; do case "$f" in *.m0|*.m1) cp "$f" "$EV/";; *) cp -r "$f" "$RES/";; esac; done
for e in $D/prefill-* $D/decode-*; do [ -f "$e/server.log" ] && gzip -c "$e/server.log" > "$EV/$(basename $e).server.log.gz"; done
grep -h -E 'Scheduler hit an exception|out of memory|malformed|DEADLINE_EXCEEDED|subtree drop declined' $D/prefill-*/server.log $D/decode-*/server.log > "$EV/invalidating_lines.txt" || true
python3 $H/offload_counters.py $PTS --json "$EV/offload_counters.json" $D/prefill-*/server.log $D/decode-*/server.log > "$EV/offload_counters.txt" 2>&1 || true
echo "$J -> $RES ($(ls $RES | wc -l) files), $EV ($(ls $EV | wc -l) files); invalidating lines: $(wc -l < $EV/invalidating_lines.txt); $(grep -c 'verdict: EQUAL' $EV/offload_counters.txt) engines EQUAL"
