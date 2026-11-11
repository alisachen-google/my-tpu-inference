#!/usr/bin/env bash
# STAGE=stress: long mixed-load stress of the deployment (any layout) through the random mini-lb and the pinned
# (prefill, decode) routers: ramp the concurrency until the system starts to fail, drain, verify (idle engines,
# a verification batch, the GSM8K quality gate, no leaked KV after a flush), repeat until STRESS_SECONDS is up.
# stress_driver.py does the work; this script wires it to the deployment, then scans the server logs for crashes
# and writes the evidence. Knobs through STAGE_ENV (all optional):
#   STRESS_SECONDS (10800) CONC_START (2) CONC_MAX (256) CONC_FACTOR (1.5) STEP_SECONDS (300) MAX_INPUT (CONTEXT_LEN-1024)
#   MAX_IMAGES (64) MAX_OUTPUT (1024) P_IMAGE (0.35) P_RETURN (0.3) P_GSM8K (0.08) P_ABORT (0.05) GSM8K_N (100)
#   HANG_SECONDS (600) TTFT_SAT_SECONDS (600) DRAIN_SECONDS (1200) VERIFY_N (24) CYCLES_MAX (0 = until time is up)
#   TTFT_TIMEOUT (900) STOP_ON_FAIL (false) SEED (1)
source "$HARNESS/common.sh"
fresh_run
log "STRESS start ($RUN, profile ${MODEL_PROFILE:-?}, multimodal ${MULTIMODAL:-false}, tp ${TP:-?}, hosts/engine ${HOSTS_PER_ENGINE:-1}, policy ${WRITE_POLICY:-?}, switch ${SWITCH:-?}, layout ${LAYOUT:-?}): $(health) $(exc)"
PINS=""
for p in $(seq 0 $((NP-1))); do for d in $(seq 0 $((ND-1))); do PINS="${PINS:+$PINS,}p${p}d${d}=$(lb_pin $p $d)"; done; done
log "pins: $PINS"
MM=""; [ "${MULTIMODAL:-false}" = true ] && MM="--multimodal"
STOP=""; [ "${STOP_ON_FAIL:-false}" = true ] && STOP="--stop-on-fail"
MAX_INPUT=${MAX_INPUT:-$(( ${CONTEXT_LEN:-262144} - 1024 ))}
snap "$OUT/${RUN}_stress.m0"; T0=$(now)
$PY $HARNESS/stress_driver.py --lb "$LB" --pins "$PINS" --prefill-urls "$PREFILL_URLS" --decode-urls "$DECODE_URLS" \
  --tokenizer "$TOK" --prompts "$PROMPTS" --gsm8k "$HARNESS/data/gsm8k_test.jsonl" --out "$OUT" --run "$RUN" \
  --served-model "${SERVED_MODEL:-model}" $MM $STOP --seed "${SEED:-1}" --duration "${STRESS_SECONDS:-10800}" --cycles-max "${CYCLES_MAX:-0}" \
  --max-input "$MAX_INPUT" --max-images "${MAX_IMAGES:-64}" --max-output "${MAX_OUTPUT:-1024}" \
  --p-image "${P_IMAGE:-0.35}" --p-return "${P_RETURN:-0.3}" --p-gsm8k "${P_GSM8K:-0.08}" --p-abort "${P_ABORT:-0.05}" \
  --conc-start "${CONC_START:-2}" --conc-max "${CONC_MAX:-256}" --conc-factor "${CONC_FACTOR:-1.5}" --step-seconds "${STEP_SECONDS:-300}" \
  --hang-seconds "${HANG_SECONDS:-600}" --ttft-sat-seconds "${TTFT_SAT_SECONDS:-600}" --drain-seconds "${DRAIN_SECONDS:-1200}" \
  --verify-n "${VERIFY_N:-24}" --gsm8k-n "${GSM8K_N:-100}" --ttft-timeout "${TTFT_TIMEOUT:-900}" --context-len "${CONTEXT_LEN:-262144}" 2>&1 | tee -a "$OUT/${RUN}_stress_driver.out"
rc=${PIPESTATUS[0]}
T1=$(now); snap "$OUT/${RUN}_stress.m1"
log "driver rc=$rc; $(hit_from_snaps $OUT/${RUN}_stress.m0 $OUT/${RUN}_stress.m1)"
# Crash and hang evidence from the server log copies: the five invalidating patterns plus the hard failures.
CRASH_PAT='Segmentation fault|core dumped|Watchdog timeout|watchdog_timeout|server exited rc=[1-9]|KV mismatch|checksum mismatch|UnsupportedDramOffloadConfig|CUDA error|HBM OOM|RESOURCE_EXHAUSTED'
crash=0; : > "$OUT/${RUN}_stress_log_scan.txt"
for f in $SHARED/prefill-*/server.log $SHARED/decode-*/server.log; do
  [ -f "$f" ] || continue
  e=$(grep -c -E "$EXC_PAT" "$f" 2>/dev/null); c=$(grep -c -E "$CRASH_PAT" "$f" 2>/dev/null); t=$(grep -c "Traceback" "$f" 2>/dev/null)
  echo "$(basename $(dirname $f)): exceptions=$e crashes=$c tracebacks=$t" | tee -a "$OUT/${RUN}_stress_log_scan.txt"
  grep -n -E "$EXC_PAT|$CRASH_PAT" "$f" 2>/dev/null | head -20 | sed "s#^#  $(basename $(dirname $f)): #" >> "$OUT/${RUN}_stress_log_scan.txt"
  crash=$((crash + e + c))
done
sleep 30; evidence | tee -a "$OUT/evidence.txt"
log "STRESS DONE ($RUN): driver rc=$rc, invalidating/crash lines=$crash, $(health) $(exc)"
[ "$crash" -gt 0 ] && rc=$((rc + 2))
exit $rc
