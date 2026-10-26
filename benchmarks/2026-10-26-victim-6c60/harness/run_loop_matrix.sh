#!/usr/bin/env bash
# Loopback H2H microbenchmark matrix on one host (run as alisachen_google_com on w8).
cd /home/alisachen_google_com/h2h_bench
export TPU_WORKER_HOSTNAMES=$(hostname) TPU_WORKER_ID=0 PYTHONPATH=/home/alisachen_google_com/h2h
out=loop_matrix.jsonl; : > $out
for pairs in 8; do for streams in 1 4; do
  echo "== pairs=$pairs streams=$streams $(date -u +%T)"
  timeout 1800 /home/alisachen_google_com/venv/sglang/bin/python h2h_loop_tpu.py --sizes 16,128,512,2176,4352 \
    --reps 5 --pairs $pairs --streams $streams --base-port $((43000 + 500*pairs + 200*streams)) > case.log 2>&1
  echo "rc=$?"; grep -E '^RESULT|FAILED|MISMATCH' case.log | tee -a $out | cut -c1-200
  grep -E 'Check failed|Traceback' case.log | head -2
done; done
echo MATRIX DONE
