#!/usr/bin/env bash
# Install Kyverno (policy engine) on the lab cluster. Kyverno runs fine on the nested Talos node —
# it's plain admission Deployments, no BTF / hostPath (unlike Tetragon, which the lab CANNOT run:
# nested Talos-in-Podman has no kernel BTF / /sys/kernel/tracing — same wall class as rbd-nbd
# #14/#15). Runs LOCALLY against the tunnel; layers the base values with the environment overlay
# values (values, not structure). Idempotent (upgrade). Ships all policies in Audit.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/env.sh"
export KUBECONFIG="$LAB_KUBECONFIG"

CHART_VERSION="${KYVERNO_VERSION:-3.8.2}"
BASE="$HERE/components/platform/kyverno/values.yaml"
ENVV="$HERE/environments/$LAB_ENV/kyverno-values.yaml"

if ! ssh -S "$LAB_SSH_SOCKET" -O check "$LAB_SSH" >/dev/null 2>&1; then
  echo "kyverno: tunnel is down — run 'make lab-tunnel' first" >&2; exit 1
fi

helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null

# namespace.yaml carries the part-of label; helm installs into it (no --create-namespace).
kubectl apply -f "$HERE/components/platform/kyverno/namespace.yaml"

echo "kyverno: helm upgrade --install (chart $CHART_VERSION) with $BASE + $ENVV"
helm upgrade --install kyverno kyverno/kyverno \
  --version "$CHART_VERSION" \
  --namespace kyverno \
  -f "$BASE" \
  ${ENVV:+-f "$ENVV"} \
  --wait --timeout 5m

echo "kyverno: applying Talu policies (Audit)"
kubectl apply -f "$HERE/components/platform/kyverno/policies/"
kubectl apply -f "$HERE/components/platform/access/kyverno-guardrails.yaml"

echo "kyverno: rollout status"
kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=5m
echo "kyverno: done. 'kubectl get polr -A' for Audit findings; 'make lab-status' for the full picture."
