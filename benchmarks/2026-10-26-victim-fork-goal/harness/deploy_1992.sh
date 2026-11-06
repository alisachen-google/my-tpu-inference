#!/usr/bin/env bash
# Deploy a worktree to ~/sglang-main on a host and bring ~/venv/sglang-main to the tree's TPU pins plus a tpu-sync
# nightly that has the host-to-host read API.   deploy_1992.sh <host-ip> <worktree> [tpu-sync version]
set -uo pipefail
ip=${1:?}; tree=${2:?}; sync_ver=${3:-0.0.1.dev20261103081657}
ME=alisachen_google_com; SA=sa_101411256518727260534
token=$(gcloud auth print-access-token 2>/dev/null)
SSH="ssh -i $HOME/.ssh/google_compute_engine -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=20"
for try in 1 2 3 4 5 6; do
  rsync -a --delete --partial --inplace --exclude .git --exclude __pycache__ --exclude '*.egg-info' --exclude 'python/pyproject.toml' \
    -e "$SSH" --rsync-path='sudo rsync' "$tree/" "$SA@$ip:/home/$ME/sglang-main/" && break
  echo "rsync retry $try"; sleep 5
done
git -C "$tree" rev-parse HEAD > /tmp/.sglang_rev_$$ && rsync -a -e "$SSH" --rsync-path='sudo rsync' /tmp/.sglang_rev_$$ "$SA@$ip:/home/$ME/sglang-main/.sglang_rev"
cat > /tmp/remote_install_$$.sh <<REMOTE
set -euo pipefail
cd /home/$ME/sglang-main
cp python/pyproject_tpu.toml python/pyproject.toml
PIP=/home/$ME/venv/sglang-main/bin/pip
REG=https://oauth2accesstoken:$token@us-python.pkg.dev/ml-oss-artifacts-transient/torch-tpu-virtual-registry/simple/
\$PIP install -q --extra-index-url https://download.pytorch.org/whl/cpu --extra-index-url \$REG -e python/ 2>&1 | grep -v oauth2accesstoken | tail -3
\$PIP install -q --no-deps -e . 2>&1 | tail -2
\$PIP install -q --no-deps --pre --extra-index-url \$REG tpu-sync-torch==$sync_ver 2>&1 | grep -v oauth2accesstoken | tail -2
\$PIP list 2>/dev/null | grep -iE "^(torch|torch_tpu|libtpu|tpu.sync.torch|sglang|sglang.tpu) "
/home/$ME/venv/sglang-main/bin/python - <<'PY'
import inspect
from tpu_sync.api.torch import kv_cache_manager as k
m = k.KVCacheManager
print("register_read:", list(inspect.signature(m.register_read).parameters))
print("start_read:", list(inspect.signature(m.start_read).parameters))
PY
echo DEPLOY_OK \$(cat .sglang_rev)
REMOTE
rsync -a -e "$SSH" --rsync-path='sudo rsync' /tmp/remote_install_$$.sh "$SA@$ip:/tmp/remote_install_1992.sh"
$SSH $SA@$ip "sudo chown -R $ME:$ME /home/$ME/sglang-main; sudo chmod 644 /tmp/remote_install_1992.sh; sudo -n -iu $ME bash /tmp/remote_install_1992.sh; sudo rm -f /tmp/remote_install_1992.sh" 2>&1 | grep -v oauth2accesstoken | tail -15
rm -f /tmp/remote_install_$$.sh /tmp/.sglang_rev_$$
