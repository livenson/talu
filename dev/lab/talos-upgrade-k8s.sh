#!/usr/bin/env bash
# Upgrade Kubernetes itself via Talos (control-plane components + kubelets), AFTER talos-upgrade.sh.
# Talos orchestrates this centrally — run once, pointed at any control-plane node.
#
# Usage:
#   talos-upgrade-k8s.sh --check     # print the command, execute nothing
#   talos-upgrade-k8s.sh             # do it
#   env: KUBERNETES_VERSION=vX.Y.Z (required), TALOSCONFIG, KUBECONFIG
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/.talu/kubeconfig}

CHECK=false; [ "${1:-}" = "--check" ] && CHECK=true
VER=${KUBERNETES_VERSION:-}
if [ -z "$VER" ]; then echo "set KUBERNETES_VERSION=vX.Y.Z" >&2; exit 2; fi

CP=$(kubectl get nodes -l node-role.kubernetes.io/control-plane \
       -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
[ -n "$CP" ] || { echo "no control-plane node found" >&2; exit 1; }

if $CHECK; then echo "would: talosctl -n $CP upgrade-k8s --to $VER"; exit 0; fi
echo "== talosctl upgrade-k8s --to $VER (via $CP) =="
talosctl -n "$CP" upgrade-k8s --to "$VER"
