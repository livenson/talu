#!/usr/bin/env bash
# Log into ANY exposed Talu VM, relying on OpenBao for the credential.
#
#   throwaway keypair -> OpenBao SSH CA signs a 15-min cert for the principal ->
#   SSH through the OIDC-gated Pomerium tunnel for THIS vm -> land in the guest.
#
# The VM is selected by name: the tunnel maps to Pomerium route ssh-<vm>.<domain>,
# which routes to Service <vm>-ssh (selector kubevirt.io/vm: <vm>). Expose a VM first
# with expose-vm.sh (creates that Service + route + pinning + opens the tunnel).
#
# Usage:  vm-ssh.sh <vm> [principal] [-- <remote command...>]
#   env: LAB_DOMAIN (default 203-0-113-10.sslip.io), BAO_ROLE (default talu)
set -euo pipefail

VM=${1:?usage: vm-ssh.sh <vm> [principal] [-- cmd...]}; shift
PRINCIPAL=talu
if [ "${1:-}" != "--" ] && [ -n "${1:-}" ]; then PRINCIPAL=$1; shift; fi
[ "${1:-}" = "--" ] && shift || true

export KUBECONFIG=${KUBECONFIG:-$HOME/.talu/kubeconfig}
DOMAIN=${LAB_DOMAIN:-203-0-113-10.sslip.io}
BAO_ROLE=${BAO_ROLE:-talu}

# Deterministic local tunnel port per VM (keeps many VMs' tunnels side by side).
PORT=${TUNNEL_PORT:-$(( 2200 + $(printf '%s' "$VM" | cksum | cut -d' ' -f1) % 300 ))}

if ! ss -ltn "sport = :$PORT" 2>/dev/null | grep -q ":$PORT"; then
  echo "No Pomerium tunnel on :$PORT for '$VM'. Run:  ./expose-vm.sh $VM <namespace>" >&2
  echo "(that creates the Service/route/pinning and opens the OIDC-gated tunnel)" >&2
  exit 1
fi

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
ssh-keygen -t ed25519 -N '' -f "$WORK/id" -q

# OpenBao signs a short-lived cert for this principal (lab: dev root token;
# prod: `bao login -method=oidc` -> scoped policy on ssh/sign/<role>).
cat "$WORK/id.pub" | kubectl -n openbao exec -i deploy/openbao -- sh -c \
  "export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=${BAO_TOKEN:-root}; cat > /tmp/k.pub; \
   bao write -field=signed_key ssh/sign/${BAO_ROLE} public_key=@/tmp/k.pub valid_principals=${PRINCIPAL}" \
  > "$WORK/id-cert.pub"
echo "OpenBao cert for ${PRINCIPAL}@${VM}:" >&2
ssh-keygen -L -f "$WORK/id-cert.pub" | grep -E 'Valid|Principals' >&2

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o CertificateFile="$WORK/id-cert.pub" -i "$WORK/id" \
  -p "$PORT" "${PRINCIPAL}@localhost" "$@"
