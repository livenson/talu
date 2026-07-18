#!/usr/bin/env bash
# Push the local working tree to the remote lab cluster through the tunnel.
# Two modes mirror the platform doc's dev-sync contract:
#
#   dev/lab/sync.sh            # inner loop: kustomize build | kubectl apply --server-side
#   dev/lab/sync.sh oci        # reconcile-semantics: flux push artifact -> remote zot OCIRepository
#
# The forge stays the source of truth; this only accelerates the loop.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/env.sh"
export KUBECONFIG="$LAB_KUBECONFIG"

if ! ssh -S "$LAB_SSH_SOCKET" -O check "$LAB_SSH" >/dev/null 2>&1; then
  echo "sync: tunnel is down — run 'make lab-tunnel' first" >&2; exit 1
fi

OVERLAY="$HERE/environments/$LAB_ENV"
[ -d "$OVERLAY" ] || { echo "sync: overlay not found: $OVERLAY" >&2; exit 1; }

# Prefer standalone kustomize; fall back to the one built into kubectl.
kbuild() { if command -v kustomize >/dev/null 2>&1; then kustomize build "$1"; else kubectl kustomize "$1"; fi; }

mode="${1:-apply}"
case "$mode" in
  apply)
    echo "sync: kustomize build $LAB_ENV | kubectl apply --server-side (Flux suspended)"
    kbuild "$OVERLAY" \
      | kubectl apply --server-side --force-conflicts -f -
    echo "sync: applied. 'make lab-status' to see reconciliation."
    ;;
  oci)
    # Full GitOps behaviour without a Git server: push the working tree as an OCI
    # artifact to the in-cluster zot (reached over the tunnel), watched by an OCIRepository.
    echo "sync: flux push artifact -> 127.0.0.1:${LAB_ZOT_PORT} (OCIRepository reconcile)"
    flux push artifact "oci://127.0.0.1:${LAB_ZOT_PORT}/talu/${LAB_ENV}:$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo working)" \
      --path="$OVERLAY" \
      --source="$(git -C "$HERE" config --get remote.origin.url 2>/dev/null || echo local)" \
      --revision="$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo working)"
    flux reconcile source oci talu-"$LAB_ENV" 2>/dev/null || true
    ;;
  *) echo "usage: $0 {apply|oci}" >&2; exit 2 ;;
esac
