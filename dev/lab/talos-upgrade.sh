#!/usr/bin/env bash
# Rolling Talos upgrade — control-plane FIRST, one node at a time (never lose etcd quorum), then workers.
# Each node is drained with node-maintenance.sh (live-migrating its VMs) before it's upgraded.
#
# Usage:
#   talos-upgrade.sh --check      # print the ordered plan + commands, execute NOTHING (safe on the lab)
#   talos-upgrade.sh              # do it (real multi-node hardware only; the Podman lab node can't
#                                 #   be upgraded in place — use --check there)
#   env: TALOS_INSTALLER_IMAGE=ghcr.io/siderolabs/installer:vX.Y.Z  (required)
#        TALOSCONFIG (talosctl config), KUBECONFIG
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/.talu/kubeconfig}
HERE=$(cd "$(dirname "$0")" && pwd)

CHECK=false; [ "${1:-}" = "--check" ] && CHECK=true
IMAGE=${TALOS_INSTALLER_IMAGE:-}
if [ -z "$IMAGE" ]; then
  echo "set TALOS_INSTALLER_IMAGE=ghcr.io/siderolabs/installer:vX.Y.Z" >&2; exit 2
fi

node_ip()      { kubectl get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'; }
cp_nodes()     { kubectl get nodes -l node-role.kubernetes.io/control-plane -o name | sed 's#node/##'; }
worker_nodes() { kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | sed 's#node/##'; }

upgrade_one() {
  local node=$1 ip; ip=$(node_ip "$node")
  echo "== $node ($ip) =="
  if $CHECK; then
    echo "   would: node-maintenance.sh drain $node"
    echo "   would: talosctl upgrade --nodes $ip --image $IMAGE --stage --wait"
    echo "   would: kubectl wait --for=condition=Ready node/$node ; talosctl -n $ip etcd status"
    echo "   would: node-maintenance.sh uncordon $node"
    return
  fi
  bash "$HERE/node-maintenance.sh" drain "$node"
  talosctl upgrade --nodes "$ip" --image "$IMAGE" --stage --wait
  kubectl wait --for=condition=Ready "node/$node" --timeout=600s
  talosctl -n "$ip" etcd status >/dev/null   # control-plane: fail loudly if etcd isn't healthy before the next node
  bash "$HERE/node-maintenance.sh" uncordon "$node"
}

echo "### Talos rolling upgrade → $IMAGE"
echo "### order: control-plane (one at a time), then workers"
for n in $(cp_nodes);     do upgrade_one "$n"; done
for n in $(worker_nodes); do upgrade_one "$n"; done
$CHECK && echo "### --check: nothing executed." || echo "### upgrade complete. Bump Kubernetes with talos-upgrade-k8s.sh."
