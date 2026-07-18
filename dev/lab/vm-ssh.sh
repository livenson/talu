#!/usr/bin/env bash
# Access a Talu VM *relying on OpenBao* for the credential.
#
#   fresh throwaway keypair  ->  OpenBao SSH CA signs a 15-min cert  ->
#   SSH through the OIDC-gated Pomerium tunnel  ->  land in the VM as $VM_USER
#
# No static password anywhere: the VM (cloud-init'd with TrustedUserCAKeys +
# PasswordAuthentication no) accepts ONLY certificates signed by the OpenBao CA.
#
# Prereqs on this host:
#   - KUBECONFIG points at the lab cluster (default ~/.talu/kubeconfig)
#   - a Pomerium TCP tunnel to the VM's sshd is listening locally, e.g.:
#       pomerium-cli tcp ssh.203-0-113-10.sslip.io:22 --listen 127.0.0.1:2222 ...
#     (that tunnel is what enforces the OIDC/Dex login — you only get :2222 after auth)
#
# Usage:  ./vm-ssh.sh [vm-user] [-- <remote command>]
#   VM_USER      guest username / cert principal   (default: talu)
#   TUNNEL_PORT  local port the Pomerium tunnel listens on (default: 2222)
#   BAO_ROLE     OpenBao ssh role to sign with      (default: talu)
set -euo pipefail

export KUBECONFIG=${KUBECONFIG:-$HOME/.talu/kubeconfig}
VM_USER=${1:-talu}; [ "${1:-}" = "--" ] && VM_USER=talu || shift || true
[ "${1:-}" = "--" ] && shift || true
TUNNEL_PORT=${TUNNEL_PORT:-2222}
BAO_ROLE=${BAO_ROLE:-talu}

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
ssh-keygen -t ed25519 -N '' -f "$WORK/id" -q

# --- OpenBao signs a short-lived cert for this principal -------------------
# Lab uses dev-mode root token. Production: `bao login -method=oidc` (Dex) so the
# token that can call ssh/sign is bound to the caller's identity + a scoped policy.
cat "$WORK/id.pub" | kubectl -n openbao exec -i deploy/openbao -- sh -c \
  "export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=${BAO_TOKEN:-root}; \
   cat > /tmp/k.pub; \
   bao write -field=signed_key ssh/sign/${BAO_ROLE} public_key=@/tmp/k.pub valid_principals=${VM_USER}" \
  > "$WORK/id-cert.pub"

echo "OpenBao-signed cert:" >&2
ssh-keygen -L -f "$WORK/id-cert.pub" | grep -E 'Valid|Principals|Extensions' -A1 | sed 's/^/  /' >&2

# --- SSH in through the OIDC-gated Pomerium tunnel ------------------------
# (not exec'd, so the trap wipes the throwaway key + cert when the session ends)
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o CertificateFile="$WORK/id-cert.pub" -i "$WORK/id" \
  -p "$TUNNEL_PORT" "${VM_USER}@localhost" "$@"
