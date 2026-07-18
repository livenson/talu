#!/usr/bin/env bash
# Provide block devices for Rook Ceph on a host that has no spare disk (the lab VM
# has a single 100 GB sda). Creates sparse backing files -> loop devices, so Ceph
# gets genuine raw block devices (real snapshots/clones), just not real spindles.
#
# Run ON the lab host (via `make lab-push` / ssh). Idempotent.
#
#   dev/loopdev/setup.sh up      # create + attach loop devices
#   dev/loopdev/setup.sh down    # detach + remove backing files
#   dev/loopdev/setup.sh list    # show current state
set -euo pipefail
BACKING_DIR="${BACKING_DIR:-/var/lib/talu/ceph-loop}"
COUNT="${OSD_COUNT:-2}"
SIZE_GB="${OSD_SIZE_GB:-25}"

need_root() { [ "$(id -u)" -eq 0 ] || exec sudo -E "$0" "$@"; }

up() {
  need_root "$@"
  mkdir -p "$BACKING_DIR"
  modprobe loop || true
  for i in $(seq 0 $((COUNT-1))); do
    f="$BACKING_DIR/osd${i}.img"
    if [ ! -f "$f" ]; then
      echo "loopdev: creating $f (${SIZE_GB}G sparse)"
      truncate -s "${SIZE_GB}G" "$f"
    fi
    if ! losetup -j "$f" | grep -q .; then
      dev=$(losetup --find --show "$f")
      echo "loopdev: attached $f -> $dev"
    else
      echo "loopdev: $f already attached ($(losetup -j "$f" | cut -d: -f1))"
    fi
  done
  echo "loopdev: Rook 'storage.devices' should reference these /dev/loopN paths."
  losetup -a | grep talu || true
}

down() {
  need_root "$@"
  for f in "$BACKING_DIR"/osd*.img; do
    [ -e "$f" ] || continue
    for dev in $(losetup -j "$f" | cut -d: -f1); do
      echo "loopdev: detaching $dev"; losetup -d "$dev" || true
    done
    rm -f "$f"; echo "loopdev: removed $f"
  done
}

list() { losetup -a | grep talu || echo "loopdev: none"; }

case "${1:-up}" in up) up "$@";; down) down "$@";; list) list;; *) echo "usage: $0 {up|down|list}" >&2; exit 2;; esac
