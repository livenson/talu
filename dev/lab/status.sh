#!/usr/bin/env bash
# Pull lab state back and render it locally — a read-only one-screen dashboard of
# the remote validation cluster. Safe to run repeatedly (e.g. `watch make lab-status`).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/env.sh"
export KUBECONFIG="$LAB_KUBECONFIG"

hr() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

if ! ssh -S "$LAB_SSH_SOCKET" -O check "$LAB_SSH" >/dev/null 2>&1; then
  echo "status: tunnel is down — run 'make lab-tunnel' first" >&2; exit 1
fi

hr "nodes"
kubectl get nodes -o wide 2>/dev/null || echo "(api unreachable)"

hr "flux reconciliation"
kubectl get kustomizations,helmreleases,ocirepositories -A 2>/dev/null \
  | grep -Ev 'True .*True' || echo "(flux not installed, or all Ready)"

hr "storage — ceph"
kubectl -n rook-ceph get cephcluster -o jsonpath='{range .items[*]}{.metadata.name}{"  health="}{.status.ceph.health}{"  phase="}{.status.phase}{"\n"}{end}' 2>/dev/null \
  || echo "(rook-ceph not installed yet)"

hr "virtual machines"
kubectl get vm,vmi -A 2>/dev/null || echo "(kubevirt not installed yet)"
kubectl get datavolume -A 2>/dev/null | grep -Ev 'Succeeded' || true

hr "access plane"
kubectl get svc -A --field-selector spec.type=LoadBalancer 2>/dev/null || true

hr "recent warnings (last 10)"
kubectl get events -A --field-selector type=Warning \
  --sort-by=.lastTimestamp 2>/dev/null | tail -10 || echo "(none)"

echo
