#!/usr/bin/env bash
# Establish/tear down a persistent SSH ControlMaster forward to the remote lab's
# Kubernetes API (and zot). One socket, reused by every other lab-* command.
#
#   dev/lab/tunnel.sh up      # open the tunnel (idempotent) and fetch kubeconfig
#   dev/lab/tunnel.sh down    # close the tunnel
#   dev/lab/tunnel.sh status  # is it up?
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/env.sh"
mkdir -p "$(dirname "$LAB_SSH_SOCKET")"

ctl() { ssh -S "$LAB_SSH_SOCKET" "$@"; }

up() {
  if ssh -S "$LAB_SSH_SOCKET" -O check "$LAB_SSH" >/dev/null 2>&1; then
    echo "tunnel: already up"
  else
    echo "tunnel: opening ControlMaster to $LAB_SSH"
    ssh -M -S "$LAB_SSH_SOCKET" -fnNT \
        -o ControlPersist=yes -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes \
        -L "${LAB_API_PORT}:127.0.0.1:6443" \
        -L "${LAB_ZOT_PORT}:127.0.0.1:5000" \
        "$LAB_SSH"
  fi
  fetch_kubeconfig
  echo "tunnel: API at https://127.0.0.1:${LAB_API_PORT}  (KUBECONFIG=$LAB_KUBECONFIG)"
}

fetch_kubeconfig() {
  mkdir -p "$(dirname "$LAB_KUBECONFIG")"
  # talosctl on the lab writes a kubeconfig pointing at 127.0.0.1:6443 (the node's local API);
  # through the tunnel that is exactly our local LAB_API_PORT. Rewrite the port if it differs.
  if ctl "$LAB_SSH" 'test -f ~/.talu/kubeconfig' 2>/dev/null; then
    ctl "$LAB_SSH" 'cat ~/.talu/kubeconfig' \
      | sed "s#server: https://127.0.0.1:6443#server: https://127.0.0.1:${LAB_API_PORT}#" \
      > "$LAB_KUBECONFIG"
    echo "tunnel: fetched kubeconfig"
  else
    echo "tunnel: no ~/.talu/kubeconfig on lab yet (run 'make up' to create the cluster)"
  fi
}

down() {
  if ssh -S "$LAB_SSH_SOCKET" -O check "$LAB_SSH" >/dev/null 2>&1; then
    ssh -S "$LAB_SSH_SOCKET" -O exit "$LAB_SSH" || true
    echo "tunnel: closed"
  else
    echo "tunnel: not running"
  fi
}

status() {
  if ssh -S "$LAB_SSH_SOCKET" -O check "$LAB_SSH" >/dev/null 2>&1; then
    echo "tunnel: UP  -> https://127.0.0.1:${LAB_API_PORT}"
  else
    echo "tunnel: DOWN"; exit 1
  fi
}

case "${1:-up}" in
  up) up ;;
  down) down ;;
  status) status ;;
  *) echo "usage: $0 {up|down|status}" >&2; exit 2 ;;
esac
