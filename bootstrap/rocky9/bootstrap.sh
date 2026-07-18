#!/usr/bin/env bash
# Talu lab host prep — Rocky 9 on OpenStack, no /dev/kvm (quick-mode / no-KVM path).
# Idempotent. Run ON the lab host (via `make lab-push`, or scp + ssh).
#
# STAGE 0 of docs/development/rocky9-validation-plan.md.
#
#   !! LOCKOUT RISK !!  On this hosting, Docker MUST carry the mandated /etc/docker/daemon.json
#   (bridge 192.168.67.1/24, MTU 1400, overlay2) BEFORE its first start, or the VM loses
#   network and needs OpenStack cloud console recovery. This script writes the file first, then starts
#   Docker, and pauses for you to confirm SSH still works from a SECOND session.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo -E "$0" "$@"

log() { printf '\033[1m[bootstrap]\033[0m %s\n' "$1"; }

# --- 0. Base tools (this image ships stripped: no tar/rsync) -----------------
log "ensuring base tools (tar, rsync, curl)"
dnf -y install tar rsync curl >/dev/null 2>&1 || true

# --- 0.5 Host MTU 1400 (CRITICAL on this hosting) ---------------------------
# The network path to these VMs only carries ~1400-byte packets, but the interface
# defaults to MTU 1500. Once Docker starts and touches forwarding/iptables, Path-MTU
# discovery breaks and any host-originated large packet (e.g. the SSH key exchange)
# is silently blackholed — locking EVERYONE out while ping/TCP-connect still work.
# Align the host interface to the path *before* Docker starts. Live change does not
# disrupt the current SSH session; nmcli makes it persist across reboots.
IFACE="$(ip route show default 2>/dev/null | awk '{print $5; exit}')"
if [ -n "${IFACE:-}" ]; then
  log "setting $IFACE MTU to 1400 (live + persistent) to match the hosting network path"
  ip link set "$IFACE" mtu 1400 || true
  CON="$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1 || true)"
  if [ -n "${CON:-}" ]; then
    nmcli con mod "$CON" 802-3-ethernet.mtu 1400 2>/dev/null \
      || nmcli con mod "$CON" ethernet.mtu 1400 2>/dev/null || true
  fi
fi

# --- 1. Docker daemon.json (BEFORE first start) -----------------------------
# Ref: https://docs.hpc.ut.ee/public/cloud/docker/
log "writing /etc/docker/daemon.json (mandated hosting config)"
mkdir -p /etc/docker
if [ ! -f /etc/docker/daemon.json ]; then
  cat > /etc/docker/daemon.json <<'JSON'
{
  "bip": "192.168.67.1/24",
  "mtu": 1400,
  "storage-driver": "overlay2",
  "default-address-pools": [
    {"base": "192.168.167.0/24", "size": 24},
    {"base": "192.168.168.0/24", "size": 24},
    {"base": "192.168.169.0/24", "size": 24},
    {"base": "192.168.170.0/24", "size": 24},
    {"base": "192.168.171.0/24", "size": 24},
    {"base": "192.168.172.0/24", "size": 24},
    {"base": "192.168.173.0/24", "size": 24},
    {"base": "192.168.174.0/24", "size": 24}
  ],
  "default-ulimits": {"nofile": {"Name": "nofile", "Soft": 65536, "Hard": 65536}}
}
JSON
else
  log "daemon.json already present — leaving as-is (verify it matches the hosting requirement)"
fi

# --- 2. Install Docker if missing -------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "installing Docker CE"
  dnf -y install dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf -y install docker-ce docker-ce-cli containerd.io
fi
log "enabling + starting Docker"
systemctl enable --now docker
usermod -aG docker "${SUDO_USER:-rocky}" || true

log "PAUSE: open a SECOND SSH session now and confirm networking still works."
log "       (this is the lockout checkpoint). Press Enter to continue, Ctrl-C to abort."
read -r _ || true

# --- 3. Kernel modules ------------------------------------------------------
log "loading + persisting kernel modules"
cat > /etc/modules-load.d/talu.conf <<'EOF'
overlay
br_netfilter
rbd
nbd
loop
EOF
for m in overlay br_netfilter rbd nbd loop; do modprobe "$m" || true; done

# --- 4. sysctls / limits (Talos-in-Docker + many pods) ----------------------
log "raising inotify / file limits"
cat > /etc/sysctl.d/99-talu.conf <<'EOF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches   = 1048576
fs.file-max                   = 2097152
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward           = 1
EOF
sysctl --system >/dev/null

# --- 5. Tooling -------------------------------------------------------------
install_bin() { # name url
  command -v "$1" >/dev/null 2>&1 && { log "$1 present"; return; }
  log "installing $1"; curl -fsSL "$2" -o "/usr/local/bin/$1"; chmod +x "/usr/local/bin/$1"
}
ARCH=amd64
install_bin kubectl  "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl"
install_bin talosctl "https://github.com/siderolabs/talos/releases/latest/download/talosctl-linux-${ARCH}"
if ! command -v helm >/dev/null 2>&1; then log "installing helm"; curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; fi
if ! command -v flux  >/dev/null 2>&1; then log "installing flux";  curl -fsSL https://fluxcd.io/install.sh | bash; fi
if ! command -v virtctl >/dev/null 2>&1; then
  log "installing virtctl"
  KV=$(curl -fsSL https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)
  curl -fsSL "https://github.com/kubevirt/kubevirt/releases/download/${KV}/virtctl-${KV}-linux-${ARCH}" -o /usr/local/bin/virtctl && chmod +x /usr/local/bin/virtctl
fi
command -v cosign >/dev/null 2>&1 || install_bin cosign "https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-${ARCH}"

# --- 6. SELinux note --------------------------------------------------------
log "SELinux stays enforcing ($(getenforce 2>/dev/null || echo unknown)). Fix labels on denials; do not disable."

log "done. Next: 'make up' (create the Talos-in-Docker cluster) then 'make lab-sync'."
