#!/usr/bin/env bash
# Rotate a platform Secret value and restart its consumer (Pomerium/Dex re-read secrets on start).
# For the credentials an operator actually rotates: Pomerium cookie/shared secret, the Dex↔Pomerium
# client secret, etc. The SSH User CA is different (needs dual-trust) — use ca-rotate.sh for that;
# cert-manager TLS auto-renews (no action, watch the TaluCertExpiringSoon alert).
#
# Usage:
#   secret-rotate.sh <namespace> <secret> <key> <deployment> [<new-value>]
#     # generates a random value if <new-value> is omitted, then rollout-restarts <deployment>.
# Example (Pomerium shared secret):  secret-rotate.sh pomerium pomerium bootstrap deploy/pomerium
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/.talu/kubeconfig}

NS=${1:?usage: secret-rotate.sh <ns> <secret> <key> <deployment> [value]}
SEC=${2:?secret}; KEY=${3:?key}; DEPLOY=${4:?deployment}
NEW=${5:-$(openssl rand -base64 32)}

echo "== rotate $NS/secret/$SEC [$KEY] =="
kubectl -n "$NS" patch secret "$SEC" -p "{\"data\":{\"$KEY\":\"$(printf %s "$NEW" | base64 | tr -d '\n')\"}}"
echo "== restart deploy/$DEPLOY (re-reads the secret) =="
kubectl -n "$NS" rollout restart "deploy/$DEPLOY"
kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout=120s | tail -1
if [ -z "${5:-}" ]; then
  echo "== rotated to a RANDOM value. If a peer needs it too (e.g. an IdP client secret), set it on both"
  echo "   sides with an explicit <new-value> instead. =="
fi
