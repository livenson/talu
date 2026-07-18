#!/usr/bin/env bash
# Real RBD storage on the no-KVM lab WITHOUT node-side OSD prep.
#
# The udev wall (and the Talos-in-container /dev isolation) live entirely in node-side OSD
# preparation and krbd mapping. So we run Ceph OUTSIDE the Talos containers — MicroCeph on the
# host, where loop-file OSDs are first-class and udev is real — and connect the k8s cluster via
# ceph-csi with the rbd-nbd mounter (userspace; krbd fails because the host-created /dev/rbdN
# never appears inside the Talos node). Result: genuine RBD StorageClass + VolumeSnapshotClass +
# COW clones + RWX-block. Validated on the lab.
#
# Prereqs: the cluster is up with Cilium bpf.masquerade=true (pods MUST have egress to reach the
# external mon). Run ON the lab host.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/env.sh"
export KUBECONFIG="${KUBECONFIG:-$HOME/.talu/kubeconfig}"
export PATH="$PATH:/usr/local/bin:/snap/bin"
POOL="${CEPH_POOL:-kubernetes}"
MC="sudo /snap/bin/microceph"

# --- 1. MicroCeph on the host (snap; loop OSDs) -----------------------------
if ! command -v /snap/bin/microceph >/dev/null 2>&1; then
  echo "[microceph] installing snapd + microceph"
  sudo dnf install -y epel-release >/dev/null 2>&1 || true
  sudo dnf install -y snapd >/dev/null 2>&1
  sudo systemctl enable --now snapd.socket
  sudo ln -sf /var/lib/snapd/snap /snap
  sudo snap wait system seed.loaded
  sudo snap install microceph
fi
if ! $MC.ceph -s >/dev/null 2>&1; then
  echo "[microceph] bootstrap + ${LAB_OSD_COUNT:-3} loop OSDs"
  $MC cluster bootstrap
  sleep 5
  $MC disk add "loop,${LAB_OSD_SIZE_GB:-4}G,${LAB_OSD_COUNT:-3}"
fi
$MC.ceph -s | sed -n '1,6p'

# --- 2. RBD pool + CSI client -----------------------------------------------
$MC.ceph osd pool create "$POOL" 32 32 >/dev/null 2>&1 || true
$MC.rbd pool init "$POOL" >/dev/null 2>&1 || true
KEY="$($MC.ceph auth get-or-create-key client.kubernetes mon 'profile rbd' osd "profile rbd pool=$POOL" mgr "profile rbd pool=$POOL")"
FSID="$($MC.ceph fsid)"
MON="$(ip -4 addr show | grep -oE 'inet 192\.168\.[0-9]+\.[0-9]+' | awk '{print $2}' | head -1):6789"
echo "[microceph] fsid=$FSID mon=$MON pool=$POOL"

# --- 3. ceph-csi-rbd, connected to the external cluster ---------------------
kubectl create ns ceph-csi-rbd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label ns ceph-csi-rbd pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
helm repo add ceph-csi https://ceph.github.io/csi-charts >/dev/null 2>&1 || true
helm repo update ceph-csi >/dev/null 2>&1
cat > /tmp/cephcsi-values.yaml <<EOF
csiConfig:
  - clusterID: "$FSID"
    monitors: ["$MON"]
provisioner: {replicaCount: 1}
storageClass:
  create: true
  name: ceph-rbd
  clusterID: "$FSID"
  pool: $POOL
  imageFeatures: "layering"
  mounter: rbd-nbd            # krbd's /dev/rbdN is invisible inside the Talos node; rbd-nbd works
  reclaimPolicy: Delete
  allowVolumeExpansion: true
secret:
  create: true
  name: csi-rbd-secret
  userID: kubernetes
  userKey: "$KEY"
EOF
helm upgrade --install ceph-csi-rbd ceph-csi/ceph-csi-rbd -n ceph-csi-rbd -f /tmp/cephcsi-values.yaml >/dev/null
kubectl -n ceph-csi-rbd rollout status deploy/ceph-csi-rbd-provisioner --timeout=180s | tail -1

# --- 4. VolumeSnapshotClass -------------------------------------------------
kubectl apply -f - >/dev/null <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata: {name: ceph-rbd-snapclass}
driver: rbd.csi.ceph.com
deletionPolicy: Delete
parameters:
  clusterID: "$FSID"
  csi.storage.k8s.io/snapshotter-secret-name: csi-rbd-secret
  csi.storage.k8s.io/snapshotter-secret-namespace: ceph-csi-rbd
EOF
echo "[microceph] done. StorageClass 'ceph-rbd' (rbd-nbd) + VolumeSnapshotClass 'ceph-rbd-snapclass' ready."
echo "[microceph] NOTE: external-snapshotter CRDs+controller must be installed (see identity/core-services step)."
