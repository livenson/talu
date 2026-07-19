#!/usr/bin/env bash
# Forge-agnostic golden-image pipeline: build (bootc, no KVM) -> scan -> publish -> sign.
# Called by the per-forge wrappers (ci/github, ci/gitlab) or the in-cluster build Job
# (components/infrastructure/image-builds/), or run directly on any host with privileged podman.
# Gates are TOGGLABLE (SCAN/SIGN) — warn/off by default; enforce in production.
#
#   IMAGE_DIR   image dir under images/ (e.g. centos-bootc)         [required]
#   REGISTRY    push target, e.g. zot.golden-images.svc:5000        [required]
#   CHANNEL     testing | stable                                    [default testing]
#   TAG         image tag (default = CHANNEL; pass a date/version for immutable tags)
#   SCAN        true|false  — Trivy HIGH/CRITICAL gate              [default false]
#   SIGN        true|false  — cosign sign the pushed digest         [default false]
#   TLS_VERIFY  true|false  — registry TLS (false for in-cluster HTTP zot)  [default true]
set -euo pipefail
IMAGE_DIR=${IMAGE_DIR:?set IMAGE_DIR}
REGISTRY=${REGISTRY:?set REGISTRY}
CHANNEL=${CHANNEL:-testing}
TAG=${TAG:-$CHANNEL}
SCAN=${SCAN:-false}
SIGN=${SIGN:-false}
TLS_VERIFY=${TLS_VERIFY:-true}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="$REGISTRY/golden/$IMAGE_DIR:$TAG"
SUDO=""; [ "$(id -u)" != 0 ] && SUDO=sudo
INSECURE=""; [ "$TLS_VERIFY" = false ] && INSECURE="--allow-insecure-registry"   # HTTP (in-cluster) zot

echo "== build $IMAGE_DIR -> $REF =="
bash "$HERE/images/build-bootc.sh" "$IMAGE_DIR" "$REF"

if [ "$SCAN" = true ]; then
  echo "== scan (Trivy, gate on HIGH/CRITICAL) =="
  trivy image --exit-code 1 --severity HIGH,CRITICAL --ignore-unfixed "$REF"
fi

echo "== publish =="
$SUDO podman push --tls-verify="$TLS_VERIFY" "$REF"

if [ "$SIGN" = true ]; then
  echo "== sign (cosign) =="
  # keyless (OIDC) by default; set COSIGN_KEY=cosign.key for key-based signing.
  cosign sign --yes ${COSIGN_KEY:+--key "$COSIGN_KEY"} $INSECURE "$REF"
fi

echo "published $REF (channel=$CHANNEL scan=$SCAN sign=$SIGN)"
echo "Promote to stable by re-tagging/pushing $REGISTRY/golden/$IMAGE_DIR:stable after acceptance."
