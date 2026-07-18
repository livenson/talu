#!/usr/bin/env bash
# Runs ON the lab host (as a user with sudo). Creates the Talos cluster as Podman containers
# via talosctl's docker provisioner (DOCKER_HOST -> Podman socket), with:
#   - CNI disabled so Cilium owns the datapath (installed next);
#   - loop-backed block devices bind-mounted in for Rook Ceph OSDs (the container is
#     privileged, so /dev/loopN is usable inside — Talos hides loop devices from
#     `get disks` but Rook's OSD pods scan /dev directly);
#   - enough memory/CPU for Ceph + the control plane (defaults of 2GiB/2CPU are too small).
# The create blocks on node-Ready until a CNI exists, so we run it backgrounded, wait for
# the k8s API, and write a kubeconfig to ~/.talu/kubeconfig.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/env.sh"
CLUSTER="${LAB_CLUSTER:-talu-lab}"
export DOCKER_HOST="$LAB_DOCKER_HOST"
TALOSCTL=/usr/local/bin/talosctl
LOG=/root/talos-create.log
CP_MEM="${LAB_CP_MEM:-16384}"      # MiB for the control-plane node (Ceph needs headroom)
CP_CPUS="${LAB_CP_CPUS:-6.0}"

echo "[remote-up] ensuring loop-backed OSD devices"
sudo OSD_COUNT="${LAB_OSD_COUNT:-2}" OSD_SIZE_GB="${LAB_OSD_SIZE_GB:-20}" bash "$HERE/dev/loopdev/setup.sh" up
mapfile -t LOOPS < <(sudo losetup -a | awk -F: '/talu\/ceph-loop/{print $1}' | sort)
echo "[remote-up] OSD loop devices: ${LOOPS[*]}"
MOUNTS=(); for d in "${LOOPS[@]}"; do MOUNTS+=(--mount "type=bind,source=$d,target=$d"); done

# Optional: share host /dev (rshared) into the node so ceph-csi rbd/nbd devices reach kubelet.
# Talos curates its own /dev (no /dev/nbd*), so kubelet can't complete rbd-nbd bind-mounts and
# CDI-to-Ceph / Ceph-backed VM disks are unreliable. The documented Talos workaround is a
# bind mount of /dev with rshared propagation (kubelet-extraMounts pattern; Ceph tracker #22012).
# EXPERIMENTAL: overlaying host /dev on Talos may interfere with Talos device management — validate.
if [ "${LAB_SHARE_HOST_DEV:-0}" = 1 ]; then
  MOUNTS+=(--mount "type=bind,source=/dev,target=/dev,bind-propagation=rshared")
fi

echo "[remote-up] (re)creating Talos/Podman cluster '$CLUSTER'"
sudo DOCKER_HOST="$DOCKER_HOST" "$TALOSCTL" cluster destroy --name "$CLUSTER" >/dev/null 2>&1 || true
sudo rm -rf "/root/.talos/clusters/$CLUSTER" 2>/dev/null || true

PATCH=/tmp/talu-talos-patch.yaml
cat > "$PATCH" <<'EOF'
cluster:
  allowSchedulingOnControlPlanes: true
  network:
    cni:
      name: none
  proxy:
    disabled: true
EOF

# setsid+background: create blocks on node-Ready (no CNI yet) — expected.
sudo bash -c "setsid env DOCKER_HOST='$DOCKER_HOST' $TALOSCTL cluster create docker \
  --name '$CLUSTER' --workers 0 \
  --memory-controlplanes $CP_MEM --cpus-controlplanes $CP_CPUS \
  --config-patch @$PATCH ${MOUNTS[*]} \
  >$LOG 2>&1 </dev/null &"

echo "[remote-up] waiting for control plane API..."
mkdir -p "$HOME/.talu"
for i in $(seq 1 40); do
  if sudo test -f /root/.kube/config && sudo grep -q 'server:' /root/.kube/config 2>/dev/null; then
    sudo cp /root/.kube/config "$HOME/.talu/kubeconfig"
    sudo cp /root/.talos/config "$HOME/.talu/talosconfig" 2>/dev/null || true
    sudo chown "$(id -u):$(id -g)" "$HOME/.talu/kubeconfig" "$HOME/.talu/talosconfig" 2>/dev/null || true
    if KUBECONFIG="$HOME/.talu/kubeconfig" kubectl get --raw /healthz >/dev/null 2>&1; then
      echo "[remote-up] k8s API healthy after ${i} checks"; break
    fi
  fi
  sleep 6
done

KUBECONFIG="$HOME/.talu/kubeconfig" kubectl get nodes 2>&1 | head -3 || true
echo "[remote-up] control plane up (node NotReady until Cilium). kubeconfig at ~/.talu/kubeconfig"
