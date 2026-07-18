#!/usr/bin/env bash
# Talu lab host prep — Rocky 9/10 on OpenStack, no /dev/kvm (quick-mode path).
# Idempotent. Run ON the lab host (via `make lab-push`, or scp + ssh).
#
# STAGE 0 of docs/development/rocky9-validation-plan.md. Container engine is PODMAN
# (Rocky-native, daemonless, no third-party repo). talosctl's docker provisioner drives
# Podman's Docker-compatible API socket via DOCKER_HOST — validated on Linux.
#
# Order is deliberate and SAFE:
#   1. Host MTU -> 1400 FIRST. The path to these VMs carries ~1400-byte packets; the
#      interface defaults to 1500. Fixing it first avoids the Path-MTU blackhole that
#      otherwise locks out SSH once container networking touches the datapath.
#   2. sysctls (incl. ip_forward) and kernel modules before the engine.
#   3. Podman API socket exposed at /run/podman/podman.sock for talosctl (DOCKER_HOST).
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -E "$0" "$@"

log() { printf '\033[1m[bootstrap]\033[0m %s\n' "$1"; }

# --- 1. Host MTU 1400 FIRST (CRITICAL on this hosting) ----------------------
IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
if [ -n "${IFACE:-}" ]; then
  log "interface $IFACE MTU $(cat "/sys/class/net/$IFACE/mtu" 2>/dev/null) -> 1400 (live + persistent)"
  ip link set "$IFACE" mtu 1400 || true
  CON="$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1 || true)"
  [ -n "${CON:-}" ] && { nmcli con mod "$CON" 802-3-ethernet.mtu 1400 2>/dev/null || nmcli con mod "$CON" ethernet.mtu 1400 2>/dev/null || true; }
fi

# --- 2. Base tools ----------------------------------------------------------
log "ensuring base tools (tar, rsync, curl)"
dnf -y install tar rsync curl >/dev/null 2>&1 || true

# --- 3. Kernel modules ------------------------------------------------------
# Minimal cloud images ship only kernel-modules-core; the full kernel-modules (nf_nat, ...)
# may be missing AND the running-kernel version is often gone from the live repo. Install
# from the Rocky vault matching $(uname -r). NOTE: RHEL/Rocky 10 is nftables-only — legacy
# ip_tables/xt_addrtype don't exist; that's fine (Podman/Cilium use nftables/eBPF).
if ! rpm -q "kernel-modules-$(uname -r)" >/dev/null 2>&1; then
  log "installing kernel-modules for $(uname -r)"
  if ! dnf -y install "kernel-modules-$(uname -r)" >/dev/null 2>&1; then
    . /etc/os-release
    K="$(uname -r)"; K="${K%.x86_64}"
    VURL="https://dl.rockylinux.org/vault/rocky/${VERSION_ID}/BaseOS/x86_64/os/Packages/k/kernel-modules-${K}.x86_64.rpm"
    log "repo miss; trying vault"
    dnf -y install "$VURL" >/dev/null 2>&1 || log "WARN: kernel-modules unavailable; some modules may be absent"
  fi
  depmod -a "$(uname -r)" 2>/dev/null || true
fi
log "loading + persisting modules (best-effort; br_netfilter may be absent on this kernel)"
cat > /etc/modules-load.d/talu.conf <<'EOF'
overlay
nf_nat
nf_conntrack
br_netfilter
rbd
nbd
loop
EOF
for m in overlay nf_nat nf_conntrack br_netfilter rbd nbd loop; do modprobe "$m" 2>/dev/null || log "  (module $m unavailable — continuing)"; done

# --- 4. sysctls / limits ----------------------------------------------------
log "applying sysctls (ip_forward, inotify, file limits)"
cat > /etc/sysctl.d/99-talu.conf <<'EOF'
net.ipv4.ip_forward           = 1
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches   = 1048576
fs.file-max                   = 2097152
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sysctl --system >/dev/null 2>&1 || true
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# --- 5. Podman + Docker-API shim + socket -----------------------------------
if ! command -v podman >/dev/null 2>&1; then
  log "installing podman + podman-docker (removes docker-ce if present)"
  dnf -y remove 'docker-ce*' containerd.io >/dev/null 2>&1 || true
  dnf -y install podman podman-docker
fi
log "enabling rootful Podman API socket (/run/podman/podman.sock)"
systemctl enable --now podman.socket
podman --version | sed 's/^/[bootstrap] /'

# --- 6. Tooling -------------------------------------------------------------
install_bin() { command -v "$1" >/dev/null 2>&1 && { log "$1 present"; return; }; log "installing $1"; curl -fsSL "$2" -o "/usr/local/bin/$1"; chmod +x "/usr/local/bin/$1"; }
ARCH=amd64
install_bin kubectl  "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
install_bin talosctl "https://github.com/siderolabs/talos/releases/latest/download/talosctl-linux-${ARCH}"
if ! command -v helm >/dev/null 2>&1; then log "installing helm"; curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || true; hash -r; fi
if ! command -v flux >/dev/null 2>&1; then log "installing flux"; curl -fsSL https://fluxcd.io/install.sh | bash || true; hash -r; fi
if ! command -v virtctl >/dev/null 2>&1; then
  log "installing virtctl"
  KV=$(curl -fsSL https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
  curl -fsSL "https://github.com/kubevirt/kubevirt/releases/download/${KV}/virtctl-${KV}-linux-${ARCH}" -o /usr/local/bin/virtctl && chmod +x /usr/local/bin/virtctl || true
fi
command -v cosign >/dev/null 2>&1 || install_bin cosign "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-${ARCH}" || true

# --- 7. SELinux note --------------------------------------------------------
log "SELinux stays enforcing ($(getenforce 2>/dev/null || echo unknown)). Fix labels on denials; do not disable."
log "done. Podman API up. Next: 'make up' (talosctl cluster create docker via DOCKER_HOST=podman)."
