#!/usr/bin/env bash
# Build + push the talu-pkg-builder toolchain image (used by the CA-trust publish Job to run non-root
# with no runtime install). Forge-agnostic — run from CI or any host with podman/buildah.
#
#   REGISTRY   push target (e.g. ghcr.io/you, quay.io/you, zot.golden-images.svc:5000)  [required]
#   TAG        image tag                                                                 [default: latest]
#   BASE       base image (build ARG)                          [default: registry.fedoraproject.org/fedora:41]
#   TLS_VERIFY true|false — registry TLS (false for in-cluster HTTP zot)                 [default: true]
#   PUSH       true|false — push after build                                             [default: true]
set -euo pipefail
REGISTRY=${REGISTRY:?set REGISTRY (e.g. ghcr.io/you or quay.io/you)}
TAG=${TAG:-latest}
BASE=${BASE:-registry.fedoraproject.org/fedora:41}
TLS_VERIFY=${TLS_VERIFY:-true}
PUSH=${PUSH:-true}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF="$REGISTRY/talu-pkg-builder:$TAG"
SUDO=""; [ "$(id -u)" != 0 ] && SUDO=sudo   # rootful podman on the lab host (as the image pipeline)

echo "== build $REF (base=$BASE) =="
$SUDO podman build --build-arg BASE="$BASE" -t "$REF" -f "$HERE/Containerfile" "$HERE"

if [ "$PUSH" = true ]; then
  echo "== push $REF (tls-verify=$TLS_VERIFY) =="
  $SUDO podman push --tls-verify="$TLS_VERIFY" "$REF"
  echo "published $REF — point publish-job/job.yaml image: at this ref (kustomize images: override)."
else
  echo "built $REF (PUSH=false — not pushed)"
fi
