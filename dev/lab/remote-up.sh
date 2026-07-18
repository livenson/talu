#!/usr/bin/env bash
# Runs ON the lab host. Creates the Talos-in-Docker cluster and writes a kubeconfig
# to ~/.talu/kubeconfig (fetched locally by dev/lab/tunnel.sh). Idempotent-ish:
# re-running destroys and recreates.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER="${LAB_CLUSTER:-talu-lab}"
mkdir -p "$HOME/.talu" /var/local-path-provisioner 2>/dev/null || sudo mkdir -p /var/local-path-provisioner

echo "[remote-up] (re)creating Talos-in-Docker cluster '$CLUSTER'"
talosctl cluster destroy --name "$CLUSTER" --provisioner docker 2>/dev/null || true

# Single node = control-plane + worker. Docker provisioner exposes the API on 127.0.0.1:6443.
talosctl cluster create \
  --provisioner docker \
  --name "$CLUSTER" \
  --controlplanes 1 --workers 0 \
  --config-patch @"$HERE/dev/talos/patch.yaml"

# Persist configs where the tunnel/kubeconfig fetch expects them.
talosctl --context "$CLUSTER" kubeconfig --force "$HOME/.talu/kubeconfig"
cp -f "$HOME/.talos/config" "$HOME/.talu/talosconfig" 2>/dev/null || true

echo "[remote-up] cluster up. kubeconfig at ~/.talu/kubeconfig"
kubectl --kubeconfig "$HOME/.talu/kubeconfig" get nodes -o wide || true
