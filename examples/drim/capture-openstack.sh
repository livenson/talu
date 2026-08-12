#!/bin/bash
# Capture a multi-disk OpenStack VM into DRIM disk artifacts, API-only.
#
# Uses nothing but the Cinder/Glance APIs, so it works against any OpenStack without access to the
# storage backend. If the DR service CAN reach the backend, prefer a native export (`rbd export`):
# `image save` below transfers the volume's PROVISIONED size and dominates wall-clock (measured:
# 358 s of a 560 s export for one 10 GiB volume). See docs/architecture/drim-target.md §10.5.
#
# MEASURED: rbd export is 4.6-5.9x faster and byte-identical (lab-notes #56). Prefer RBD=1 wherever
# the DR service can reach the storage layer; the API path stays the portable default.
#
#   source ~/overcloudrc
#   SNAPSHOTS="snap-root snap-data1" OUTDIR=./export ./capture-openstack.sh
#   RBD=1 RBD_HOST=<ctrl-running-cinder-volume> SNAPSHOTS="..." ./capture-openstack.sh
set -eu
: "${SNAPSHOTS:?space-separated Cinder snapshot names or IDs}"
OUTDIR="${OUTDIR:-./drim-export}"; VOLTYPE="${VOLTYPE:-}"
mkdir -p "$OUTDIR"; cd "$OUTDIR"

# Backend-native path. The cinder-volume container already holds ceph.conf + the keyring, so no new
# credential is created — but note that keyring can read EVERY tenant's volumes.
# Find its host with `sudo pcs status` (it is a pacemaker bundle and moves between controllers), and
# reach controllers on the CTLPLANE addresses from ~/overcloud-deploy/*/tripleo-ansible-inventory.yaml.
if [ "${RBD:-0}" = "1" ]; then
  : "${RBD_HOST:?set RBD_HOST to the controller running openstack-cinder-volume-podman-0}"
  CVC="${CVC:-openstack-cinder-volume-podman-0}"
  for snap in $SNAPSHOTS; do
    out=$(echo "$snap" | tr -c 'a-zA-Z0-9._-' '-')
    SNAP=$(openstack volume snapshot show "$snap" -f value -c id)
    VOL=$(openstack volume snapshot show "$snap" -f value -c volume_id)
    t0=$(date +%s)
    # DRIM §6.1: Cinder identity -> backend name, resolved at capture time.
    ssh "${RBD_USER:-tripleo-admin}@$RBD_HOST" \
      "sudo podman exec $CVC rbd -p ${RBD_POOL:-volumes} --id ${RBD_ID:-openstack} \
         export volume-$VOL@snapshot-$SNAP -" \
      | gzip -1 > "$out.raw.gz"
    printf "  %-24s rbd export+gzip %4ds -> %s bytes\n" "$out" "$(( $(date +%s) - t0 ))" "$(stat -c %s "$out.raw.gz")"
    cat > "$out.meta.json" <<META
{"role":"system","compression":"gzip",
 "resolvedBackend":{"driver":"rbd","pool":"${RBD_POOL:-volumes}","image":"volume-$VOL","snapshot":"snapshot-$SNAP"}}
META
  done
  echo "artifacts in $OUTDIR"; exit 0
fi

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
  # gzip, NOT zstd: CDI's zstd path is undocumented and flaky (lab-notes #54), gz is advertised.
  gzip -1 -f "$out.raw"
  S "gzip"
  printf "    gz=%s\n" "$(stat -c %s "$out.raw.gz")"
  openstack image delete "$IID" >/dev/null 2>&1 || true
  openstack volume delete "$VID" >/dev/null 2>&1 || true
done
echo "artifacts in $OUTDIR"
