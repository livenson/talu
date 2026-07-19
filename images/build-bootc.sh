#!/usr/bin/env bash
# Build a bootc golden image into a KubeVirt containerDisk — WITHOUT nested virt.
# bootc-image-builder needs --privileged (loopback) but NOT /dev/kvm for a rootful build; KVM is only
# for rootless builds and boot-testing. Runs anywhere with privileged podman: a CI runner, a build host,
# or an in-cluster privileged Job — NOT inside the nested-lab node (loop-in-nested is fragile).
#
# Usage:  build-bootc.sh <image-dir> <containerdisk-ref>
#   e.g.  build-bootc.sh centos-bootc registry.example/golden/centos-bootc:testing
set -euxo pipefail
DIR=${1:?image dir under images/}
DISK_REF=${2:?output containerDisk ref}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="localhost/talu-golden-${DIR}:latest"
OUT="$HERE/$DIR/output"
BIB=${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}
# root-in-container needs no sudo; a host user does. (CI/Job pods run as root.)
SUDO=""; [ "$(id -u)" != 0 ] && SUDO=sudo

# 1) Build the bootc app image (bake capabilities).
$SUDO podman build -t "$APP" -f "$HERE/$DIR/Containerfile" "$HERE/$DIR"

# 2) bootc-image-builder -> qcow2 (rootful + privileged, no KVM).
rm -rf "$OUT"; mkdir -p "$OUT"
$SUDO podman run --rm --privileged --security-opt label=type:unconfined_t \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$OUT":/output \
  "$BIB" --type qcow2 --local "$APP"

# 3) sparsify + wrap the qcow2 into a scratch containerDisk (KubeVirt expects the disk at /disk/).
QCOW="$OUT/qcow2/disk.qcow2"
test -f "$QCOW"
command -v virt-sparsify >/dev/null && $SUDO virt-sparsify --in-place "$QCOW" || echo "virt-sparsify absent — skipping"
cat > "$OUT/Containerfile.disk" <<EOF
FROM scratch
ADD --chown=107:107 qcow2/disk.qcow2 /disk/disk.qcow2
EOF
$SUDO podman build -t "$DISK_REF" -f "$OUT/Containerfile.disk" "$OUT"
echo "BUILT_CONTAINERDISK=$DISK_REF"
$SUDO podman images "$DISK_REF"
