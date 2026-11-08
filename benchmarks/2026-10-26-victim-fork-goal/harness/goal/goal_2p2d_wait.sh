#!/usr/bin/env bash
# After the 2P1D and 1P2D-off stages on .246/g/v7: wait for a fourth usable host (a, b, .42 or .99: no chip holder, TPU
# session starts), then run 2P2D switch-on and switch-off with sticky routes: prefills .246 + X -> decodes v7 + g.
L=$HOME/pd_disagg/live; SSHO="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o LogLevel=ERROR"
log() { echo "$(date -u '+%F %T') $*" >> $L/goal_followup.log; }
PROBE='cd /tmp && rm -rf /tmp/alisachen_tpu_probe && TPU_LOG_DIR=/tmp/alisachen_tpu_probe timeout 150 ~/venv/sglang-main/bin/python -c "import torch, torch_tpu; x=torch.ones(4, device=\"tpu\"); print(\"TPU_OK\", (x*2).sum().item())" 2>&1 | tail -1'
usable() { # ip -> 0 if no holder and the TPU answers
  local ip=$1 h r
  h=$(timeout 40 $SSHO sa_101411256518727260534@$ip "sudo -n fuser -v /dev/vfio/* 2>&1 | awk 'NR>1' | wc -l; ps -eo cmd | grep -c '[r]aylet'" 2>/dev/null | tr '\n' ' ')
  case "$h" in "0 0 ") ;; *) return 1;; esac
  if [ "$ip" = 10.128.0.90 ]; then r=$(bash -lc "$PROBE" 2>&1 | tail -1); sudo rm -f /tmp/libtpu_lockfile
  else r=$(timeout 200 $SSHO sa_101411256518727260534@$ip "sudo rm -f /tmp/libtpu_lockfile; sudo -n -iu alisachen_google_com bash -lc '$PROBE'; sudo rm -f /tmp/libtpu_lockfile" 2>&1 | tail -1); fi
  case "$r" in *TPU_OK*) return 0;; *) return 1;; esac
}
until grep -q "GOAL NEWHOSTS2 DONE" $L/goal_followup.log; do sleep 60; done
X=""; n=0
while [ -z "$X" ]; do
  n=$((n+1))
  for ip in 10.128.15.217 10.128.0.90 10.128.1.42 10.128.1.99; do usable $ip && { X=$ip; break; }; done
  [ -z "$X" ] && { [ $((n % 6)) = 1 ] && log "2P2D waits for a fourth host (a, b, .42, .99 all busy or wedged; try $n)"; sleep 600; }
done
log "2P2D fourth host: $X; prefills .246 + $X -> decodes v7 + g (switch on, then off)"
python3 - "$X" <<'PY'
import re, sys, os
X = sys.argv[1]; L = os.path.expanduser('~/pd_disagg/live')
def retarget(src, dst, amap, extra=()):
    s = open(f'{L}/{src}').read()
    for var, ip in amap.items():
        s, n = re.subn(rf'\b{var}=10\.128\.\d+\.\d+\b', f'{var}={ip}', s, count=1); assert n == 1, (src, var)
    for a, b in extra:
        assert a in s, (src, a[:50]); s = s.replace(a, b)
    open(f'{L}/{dst}', 'w').write(s)
retarget('goal_2p2d_new.sh', 'goal_2p2d_final.sh', {'A': '10.128.0.246', 'B': X, 'V': '10.128.15.239', 'G': '10.128.0.175'},
         [('RUN=g1992b_2p2d_3', 'RUN=g1992b_2p2d_4'), ('log "GOAL 2P2D NEWHOSTS DONE"', 'log "GOAL 2P2D FINAL DONE"')])
# switch-off 2P2D baseline: the 2P2D block of goal_baseline.sh only
b = open(f'{L}/goal_baseline.sh').read()
i = b.index('# ---- 2P2D off'); j = b.index('log "GOAL BASELINE DONE"')
head = b[:b.index('until [')]; block = b[i:j]
s = head + block + 'log "GOAL BASELINE 2P2D DONE"\n'
s, n = re.subn(r'\bA=10\.128\.\d+\.\d+\b', 'A=10.128.0.246', s, count=1); assert n == 1
s, n = re.subn(r'\bB=10\.128\.\d+\.\d+\b', f'B={X}', s, count=1); assert n == 1
s, n = re.subn(r'\bV=10\.128\.\d+\.\d+\b', 'V=10.128.15.239', s, count=1); assert n == 1
s, n = re.subn(r'\bG=10\.128\.\d+\.\d+\b', 'G=10.128.0.175', s, count=1); assert n == 1
s = s.replace('RUN=g1992b_2p2d_off_1', 'RUN=g1992b_2p2d_off_4')
open(f'{L}/goal_baseline_2p2d_final.sh', 'w').write(s)
PY
bash -n $L/goal_2p2d_final.sh && bash -n $L/goal_baseline_2p2d_final.sh || { log "2P2D scripts failed syntax check"; exit 1; }
bash $L/goal_2p2d_final.sh > $L/goal_2p2d_final.out 2>&1
bash $L/goal_baseline_2p2d_final.sh > $L/goal_baseline_2p2d_final.out 2>&1
log "GOAL ALL DONE"
