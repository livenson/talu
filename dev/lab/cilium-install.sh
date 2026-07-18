#!/usr/bin/env bash
# Bring up Cilium as the CNI on the lab cluster (bootstrap step — CNI must exist before
# Flux/other workloads schedule). Runs LOCALLY against the tunnel; layers the base Talos
# values with the environment overlay values (values, not structure). Idempotent (upgrade).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/env.sh"
export KUBECONFIG="$LAB_KUBECONFIG"

CHART_VERSION="${CILIUM_VERSION:-1.18.1}"
BASE="$HERE/components/infrastructure/cilium/values.yaml"
ENVV="$HERE/environments/$LAB_ENV/cilium-values.yaml"

if ! ssh -S "$LAB_SSH_SOCKET" -O check "$LAB_SSH" >/dev/null 2>&1; then
  echo "cilium: tunnel is down — run 'make lab-tunnel' first" >&2; exit 1
fi

helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

echo "cilium: helm upgrade --install (chart $CHART_VERSION) with $BASE + $ENVV"
helm upgrade --install cilium cilium/cilium \
  --version "$CHART_VERSION" \
  --namespace kube-system \
  -f "$BASE" \
  ${ENVV:+-f "$ENVV"} \
  --wait --timeout 5m

echo "cilium: rollout status"
kubectl -n kube-system rollout status ds/cilium --timeout=5m
kubectl get nodes -o wide
echo "cilium: done. 'make lab-status' for the full picture."
