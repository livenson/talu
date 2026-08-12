#!/bin/bash
# Capture a multi-disk OpenStack VM into DRIM disk artifacts, API-only.
#
# Uses nothing but the Cinder/Glance APIs, so it works against any OpenStack without access to the
# storage backend. If the DR service CAN reach the backend, prefer a native export (`rbd export`):
# `image save` below transfers the volume's PROVISIONED size and dominates wall-clock (measured:
# 358 s of a 560 s export for one 10 GiB volume). See docs/architecture/drim-target.md §10.5.
#
#   source ~/overcloudrc
#   SNAPSHOTS="snap-root snap-data1" OUTDIR=./export ./capture-openstack.sh
set -eu
: "${SNAPSHOTS:?space-separated Cinder snapshot names or IDs}"
OUTDIR="${OUTDIR:-./drim-export}"; VOLTYPE="${VOLTYPE:-}"
mkdir -p "$OUTDIR"; cd "$OUTDIR"

for snap in $SNAPSHOTS; do
  out=$(echo "$snap" | tr -c 'a-zA-Z0-9._-' '-')
  t0=$(date +%s); S(){ printf "    %-26s %5ds\n" "$1" $(( $(date +%s) - t0 )); t0=$(date +%s); }
  echo "  == $out =="
  SNAP=$(openstack volume snapshot show "$snap" -f value -c id)
  # Always work by ID: a failed run can leave two volumes with the SAME name, after which every
  # name-based lookup fails with "Multiple volume matches found" — including the cleanup.
  VID=$(openstack volume create --snapshot "$SNAP" ${VOLTYPE:+--type "$VOLTYPE"} "tmp-$out" -f value -c id)
  until [ "$(openstack volume show "$VID" -f value -c status)" = "available" ]; do sleep 3; done
  S "volume from snapshot"
  # `openstack image create --volume` is broken on RHOSP 17 ("Uploading data and using container are
  # not allowed at the same time"); the deprecated cinder CLI is the working path. lab-notes #52.
  IID=$(cinder upload-to-image --disk-format raw "$VID" "img-$out" 2>/dev/null | awk '/image_id/{print $4}')
  until [ "$(openstack image show "$IID" -f value -c status 2>/dev/null)" = "active" ]; do sleep 5; done
  S "cinder upload-to-image"
  openstack image save --file "$out.raw" "$IID"
  S "glance download"
  qemu-img convert -O raw -S 4k "$out.raw" "$out.sparse" && mv "$out.sparse" "$out.raw"
  S "sparsify"
  sha256sum "$out.raw" | cut -d' ' -f1 > "$out.raw.sha256"
  zstd -q -f "$out.raw" -o "$out.raw.zst"
  S "zstd"
  printf "    raw=%s zst=%s\n" "$(stat -c %s "$out.raw")" "$(stat -c %s "$out.raw.zst")"
  rm -f "$out.raw"
  openstack image delete "$IID" >/dev/null 2>&1 || true
  openstack volume delete "$VID" >/dev/null 2>&1 || true
done
echo "artifacts in $OUTDIR"
