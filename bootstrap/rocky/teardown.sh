#!/usr/bin/env bash
# Wipe the lab cluster + loop devices, keep the host itself sane. Run ON the lab host.
# Leaves Docker + daemon.json in place (removing them risks the network-lockout path again).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "[teardown] destroying Talos-in-Docker cluster"
talosctl cluster destroy --name talu-lab --provisioner docker 2>/dev/null || true

echo "[teardown] detaching Ceph loop devices"
if [ -x "$HERE/dev/loopdev/setup.sh" ]; then "$HERE/dev/loopdev/setup.sh" down || true; fi

echo "[teardown] pruning dangling docker state"
docker system prune -f >/dev/null 2>&1 || true

echo "[teardown] done. Docker + /etc/docker/daemon.json intentionally left in place."
