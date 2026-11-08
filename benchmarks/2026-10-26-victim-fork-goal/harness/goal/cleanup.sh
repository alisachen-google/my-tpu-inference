#!/usr/bin/env bash
# Kill OUR servers only (never another user's), remove stale lock/shm files owned by us.
me=$(id -un)
pkill -u "$me" -f 'sglang.launch_server' ; pkill -u "$me" -f 'sglang::' ; pkill -u "$me" -f 'sglang_router' ; sleep 3
pkill -9 -u "$me" -f 'sglang.launch_server' ; pkill -9 -u "$me" -f 'sglang::' ; pkill -9 -u "$me" -f 'sglang_router' ; true
find /dev/shm -maxdepth 1 -user "$me" \( -name 'sgl*' -o -name 'sem.*' -o -name 'torch*' \) -delete 2>/dev/null
[ -O /tmp/libtpu_lockfile ] && rm -f /tmp/libtpu_lockfile
# A killed engine releases its TPU device nodes and the raiden control port only after its teardown: wait for that,
# or the next launch fails with "device node already opened by another process" / "Failed to bind gRPC control server".
for i in $(seq 1 36); do
  held=$(sudo -n fuser -v /dev/vfio/* 2>&1 | awk 'NR>1{print $(NF-3)}' | grep -c "^$me$")
  ports=$(ss -ltn 2>/dev/null | grep -cE ':(30000|31000|41193|8080|8998) ')
  [ "$held" = 0 ] && [ "$ports" = 0 ] && break
  sleep 5
done
echo "[cleanup] waited $((i*5)) s for TPU and ports: held=$held listening=$ports"
echo "[cleanup] remaining sglang procs (all users): $(pgrep -fc 'sglang.launch_server|sglang::scheduler')  TPU holders: $(sudo -n fuser -v /dev/vfio/0 2>&1 | awk 'NR>1{print $(NF-3)}' | sort -u | tr '\n' ' ')"
