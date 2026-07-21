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
#   SCAN        true|false  — Trivy scan (NON-GATING on bootc; needs SBOM — see note below) [default false]
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
  # WARNING (validated on the lab, 2026-07): plain `trivy image` does NOT gate OS packages on
  # bootc/ostree images. In the static image layers the rootfs is an ostree object store
  # (/sysroot/ostree/repo/objects/, content-addressed); /etc/os-release and the rpmdb
  # (/usr/share/rpm/rpmdb.sqlite via an ostree symlink chain) only materialise at boot. So trivy
  # reports `Detected OS: None` and finds 0 of the image's 478 rpm packages — it only surfaces
  # Go-binary CVEs from embedded tooling (bootc/skopeo). Scanning $REF (the containerDisk, a scratch
  # qcow2 wrapper) finds literally nothing.
  # A REAL OS gate needs a build-time SBOM: have build-bootc.sh / bootc-image-builder emit one while
  # the rootfs is mounted, then `trivy sbom <sbom.json> --exit-code 1 --severity HIGH,CRITICAL`.
  # Until that is wired this is a best-effort, NON-BLOCKING scan of the app image for the Go-binary
  # signal only — it is NOT an OS-CVE gate. Do not treat a green SCAN as "no OS CVEs".
  APP="localhost/talu-golden-${IMAGE_DIR}:latest"
  echo "== scan (Trivy, NON-GATING — bootc OS packages need an SBOM; see comment) =="
  trivy image --severity HIGH,CRITICAL --ignore-unfixed "$APP" || true
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
