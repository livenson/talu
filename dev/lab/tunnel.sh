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
  forward_talos_api
  echo "tunnel: API at https://127.0.0.1:${LAB_API_PORT}  (KUBECONFIG=$LAB_KUBECONFIG)"
}

# The Talos API (:50000) is published on a RANDOM host port by the docker provisioner, so it can't be a
# static -L at connect time (like the k8s API). Discover it from the running controlplane container,
# add the forward to the live ControlMaster, and fetch/rewrite talosconfig — the talosctl analogue of
# fetch_kubeconfig. This is the piece that makes the lab drivable from a laptop (CLAUDE.md TODO).
forward_talos_api() {
  local hostport
  # `podman port <ctr> 50000` prints e.g. `127.0.0.1:36081`; take the port.
  hostport=$(ctl "$LAB_SSH" "sudo podman port ${LAB_CLUSTER}-controlplane-1 50000/tcp 2>/dev/null | head -1 | sed 's/.*://'" 2>/dev/null || true)
  if [ -z "$hostport" ]; then
    echo "tunnel: no Talos API port found (cluster not up? — 'make up' first). Skipping talosctl forward."
    return 0
  fi
  # add the forward to the existing master (idempotent: -O cancel first, ignore if absent)
  ssh -S "$LAB_SSH_SOCKET" -O cancel -L "${LAB_TALOS_PORT}:127.0.0.1:${hostport}" "$LAB_SSH" >/dev/null 2>&1 || true
  ssh -S "$LAB_SSH_SOCKET" -O forward -L "${LAB_TALOS_PORT}:127.0.0.1:${hostport}" "$LAB_SSH"
  fetch_talosconfig
  echo "tunnel: Talos API at https://127.0.0.1:${LAB_TALOS_PORT}  (TALOSCONFIG=$LAB_TALOSCONFIG)"
}

fetch_talosconfig() {
  mkdir -p "$(dirname "$LAB_TALOSCONFIG")"
  # rewrite the current context's endpoint (127.0.0.1:<randomport>) to our stable local port.
  if ctl "$LAB_SSH" 'sudo test -f /root/.talos/config' 2>/dev/null; then
    ctl "$LAB_SSH" 'sudo cat /root/.talos/config' \
      | sed -E "s#127\.0\.0\.1:[0-9]+#127.0.0.1:${LAB_TALOS_PORT}#g" \
      > "$LAB_TALOSCONFIG"
    echo "tunnel: fetched talosconfig (talosctl --talosconfig $LAB_TALOSCONFIG ...)"
  else
    echo "tunnel: no /root/.talos/config on lab yet"
  fi
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
