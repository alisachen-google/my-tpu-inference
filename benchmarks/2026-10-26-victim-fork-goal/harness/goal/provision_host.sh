#!/usr/bin/env bash
# Provision a borrowed tpu7x host for our engines, exactly as host g was: provision_host.sh <ip> [<tree to deploy>]
# Needs: the service-account ssh path to the host; this VM's venv copy at /dev/shm/alisachen_venv/sglang-main.
set -uo pipefail
ip=${1:?ip}; tree=${2:-$HOME/sglang-1992}; ME=alisachen_google_com
SSH="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=15 sa_101411256518727260534@$ip"
rs() { rsync -a -e "ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no" --rsync-path="sudo rsync" --chown=$ME:$ME "$@"; }
echo "== $ip: account, home, sudo rule for fuser, NFS weights, tmpfs cache dirs"
$SSH "id $ME >/dev/null 2>&1 || { echo 'no OS Login account for $ME on this host'; exit 2; }
  sudo mkdir -p /home/$ME && sudo chown $ME:$ME /home/$ME && sudo chmod 750 /home/$ME
  echo '$ME ALL=(ALL) NOPASSWD: /usr/bin/fuser' | sudo tee /etc/sudoers.d/alisachen-fuser >/dev/null && sudo chmod 440 /etc/sudoers.d/alisachen-fuser
  sudo mkdir -p /mnt/data; mount | grep -q ' /mnt/data ' || sudo mount -t nfs -o ro,noatime 10.197.251.130:/data /mnt/data; ls /mnt/data/tt/hf-cache/hub | head -1
  sudo mkdir -p /dev/shm/torch_tpu_cache && sudo chmod 1777 /dev/shm/torch_tpu_cache
  sudo -n -iu $ME bash -lc 'mkdir -p ~/venv ~/pd_disagg/results/runs ~/pd_disagg/live ~/pd_disagg/scripts /dev/shm/alisachen_cache/tier3 /dev/shm/alisachen_cache/inductor; ls /dev/vfio | grep -c \"^[0-9]\"; df -h / | tail -1'" || exit $?
echo "== $ip: stale TPU lock file (no holder) removed if present"
$SSH "h=\$(sudo -n fuser -v /dev/vfio/* 2>&1 | awk 'NR>1' | wc -l); [ \$h = 0 ] && sudo rm -f /tmp/libtpu_lockfile; echo holders=\$h"
echo "== $ip: venv (4.8 GB, retried until complete), scripts, recipes"
for try in 1 2 3 4 5 6; do rs /dev/shm/alisachen_venv/sglang-main/ sa_101411256518727260534@$ip:/home/$ME/venv/sglang-main/ && break; echo "venv rsync retry $try"; sleep 5; done
$SSH "sudo -n -iu $ME bash -lc '~/venv/sglang-main/bin/python -c \"import pip, torch; print(\\\"venv ok\\\", torch.__version__)\"'" || { echo "venv incomplete on $ip"; exit 1; }
rs $HOME/pd_disagg/scripts/launch_role.sh $HOME/pd_disagg/scripts/env_singlehost_v7x.sh $HOME/pd_disagg/scripts/cleanup.sh $HOME/pd_disagg/scripts/pd_group.sh $HOME/pd_disagg/scripts/pd_main.sh $HOME/pd_disagg/scripts/pd_1p2d.sh sa_101411256518727260534@$ip:/home/$ME/pd_disagg/scripts/
rs $HOME/pd_disagg/live/*.json sa_101411256518727260534@$ip:/home/$ME/pd_disagg/live/
echo "== $ip: deploy $tree"
bash $HOME/pd_disagg/live/deploy_1992.sh $ip $tree > $HOME/pd_disagg/live/deploy_$ip.log 2>&1; grep -q DEPLOY_OK $HOME/pd_disagg/live/deploy_$ip.log && echo DEPLOY_OK || { tail -5 $HOME/pd_disagg/live/deploy_$ip.log; exit 1; }
echo "== $ip: TPU probe"
$SSH "sudo -n -iu $ME bash -lc 'cd /tmp && TPU_LOG_DIR=/tmp/alisachen_tpu_probe timeout 240 ~/venv/sglang-main/bin/python -c \"import torch, torch_tpu; x=torch.ones(4, device=\\\"tpu\\\"); print(\\\"TPU_OK\\\", (x*2).sum().item())\" 2>&1 | tail -1'"
