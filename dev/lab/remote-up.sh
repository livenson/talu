#!/usr/bin/env bash
# Runs ON the lab host (as a user with sudo). Creates the Talos cluster as Podman containers
# via talosctl's docker provisioner (DOCKER_HOST -> Podman socket), with CNI disabled so
# Cilium can own the datapath. The create blocks on node-Ready until a CNI exists, so we run
# it backgrounded, wait for the k8s API, and write a kubeconfig to ~/.talu/kubeconfig.
# Cilium is installed next (dev/lab/cilium-install.sh) which brings the node Ready.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/env.sh"
CLUSTER="${LAB_CLUSTER:-talu-lab}"
export DOCKER_HOST="$LAB_DOCKER_HOST"
TALOSCTL=/usr/local/bin/talosctl
LOG=/root/talos-create.log

echo "[remote-up] (re)creating Talos/Podman cluster '$CLUSTER' (cni=none for Cilium)"
sudo DOCKER_HOST="$DOCKER_HOST" "$TALOSCTL" cluster destroy --name "$CLUSTER" >/dev/null 2>&1 || true
sudo rm -rf "/root/.talos/clusters/$CLUSTER" 2>/dev/null || true

# Machine-config patch: Cilium owns CNI + kube-proxy; single node is schedulable.
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

# Backgrounded: create blocks on node-Ready (no CNI yet) — that's expected.
sudo bash -c "setsid env DOCKER_HOST='$DOCKER_HOST' $TALOSCTL cluster create docker \
  --name '$CLUSTER' --workers 0 --config-patch @$PATCH >$LOG 2>&1 </dev/null &"

echo "[remote-up] waiting for control plane API..."
mkdir -p "$HOME/.talu"
for i in $(seq 1 40); do
  if sudo test -f /root/.kube/config && sudo grep -q 'server:' /root/.kube/config 2>/dev/null; then
    sudo cp /root/.kube/config "$HOME/.talu/kubeconfig"
    sudo cp /root/.talos/config "$HOME/.talu/talosconfig" 2>/dev/null || true
    sudo chown "$(id -u):$(id -g)" "$HOME/.talu/kubeconfig" "$HOME/.talu/talosconfig" 2>/dev/null || true
    if KUBECONFIG="$HOME/.talu/kubeconfig" kubectl get --raw /healthz >/dev/null 2>&1; then
      echo "[remote-up] k8s API healthy after ${i} checks"
      break
    fi
  fi
  sleep 6
done

KUBECONFIG="$HOME/.talu/kubeconfig" kubectl get nodes 2>&1 | head -3 || true
echo "[remote-up] control plane up (node NotReady until Cilium). kubeconfig at ~/.talu/kubeconfig"
echo "[remote-up] next: install Cilium (make cilium / dev/lab/cilium-install.sh)."
