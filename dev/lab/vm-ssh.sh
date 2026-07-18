#!/usr/bin/env bash
# Log into an exposed Talu VM via Pomerium Native SSH.
#
#   ssh <principal>@<vm>@ssh.<domain> -p <port>
#     -> Pomerium SSH proxy -> browser OIDC (Dex) on first connect
#     -> Pomerium issues a short-lived cert (its own User CA) -> lands in the VM.
#
# No tunnel, no OpenBao, no custom client — this is a thin wrapper over stock `ssh` that
# just fills in the endpoint/port. The VM is selected by the MIDDLE token (the Pomerium
# ssh:// route name); expose it first with expose-vm.sh (Service + route + pinning).
#
# Usage:  vm-ssh.sh <vm> [principal] [-- <remote command...>]
#   env: LAB_DOMAIN (203-0-113-10.sslip.io), SSH_ENDPOINT (ssh.<domain>), SSH_PORT (23)
set -euo pipefail

VM=${1:?usage: vm-ssh.sh <vm> [principal] [-- cmd...]}; shift
PRINCIPAL=talu
if [ "${1:-}" != "--" ] && [ -n "${1:-}" ]; then PRINCIPAL=$1; shift; fi
[ "${1:-}" = "--" ] && shift || true

DOMAIN=${LAB_DOMAIN:-203-0-113-10.sslip.io}
ENDPOINT=${SSH_ENDPOINT:-ssh.$DOMAIN}
PORT=${SSH_PORT:-23}

echo "Pomerium native SSH -> ${PRINCIPAL}@${VM}@${ENDPOINT}:${PORT}" >&2
echo "(first connect opens a browser URL for OIDC login; approve 'Verify Sign In')" >&2
exec ssh -p "$PORT" -o StrictHostKeyChecking=accept-new \
  "${PRINCIPAL}@${VM}@${ENDPOINT}" "$@"
