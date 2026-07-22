#!/usr/bin/env bash
# Build the `talu-ca-trust` .deb — the package that OWNS the SSH User CA trust on mutable guests.
#
# Why a package (not a cloud-init-written file): dpkg tracks /etc/ssh/talu_ca.pub, so `apt upgrade`
# replaces it cleanly on rotation — no ostree /etc-merge conflict, no cloud-init local-override. The
# guest installs it once (cloud-init `packages:`) then dnf-automatic/unattended-upgrades auto-updates
# it; the postinst RELOADS sshd (never restart — that would drop the platform's own session).
#
# Rotation = publish a new VERSION with the new trust file (dual-CA during the window, then new-only).
#
# Usage:
#   build-deb.sh <ca-pubkey-file> <version> [outdir]
#   # <ca-pubkey-file> may contain ONE or TWO CA public keys, one per line (the dual-trust window).
# Portable: needs only coreutils + tar + ar (GNU binutils) — NOT dpkg-deb, so it builds on Rocky too.
set -euo pipefail

CA_PUB=${1:?usage: build-deb.sh <ca-pubkey-file> <version> [outdir]}
VERSION=${2:?version, e.g. 1 or 2 (bump on every CA change)}
OUTDIR=${3:-.}
[ -s "$CA_PUB" ] || { echo "CA pubkey file '$CA_PUB' is empty/missing" >&2; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/root"; mkdir -p "$ROOT/etc/ssh/sshd_config.d" "$WORK/ctl"

install -m0644 "$CA_PUB" "$ROOT/etc/ssh/talu_ca.pub"
cat > "$ROOT/etc/ssh/sshd_config.d/60-talu-ca.conf" <<'EOF'
# Managed by the talu-ca-trust package — do not edit; rotate by publishing a new package version.
TrustedUserCAKeys /etc/ssh/talu_ca.pub
PasswordAuthentication no
EOF

# --- control archive: control + postinst + conffiles + md5sums --------------------------------
cat > "$WORK/ctl/control" <<EOF
Package: talu-ca-trust
Version: $VERSION
Architecture: all
Maintainer: Talu <ops@talu.local>
Section: admin
Priority: optional
Description: Talu SSH User CA trust
 Installs the Pomerium SSH User CA public key(s) that this cluster's VMs trust
 (TrustedUserCAKeys). Rotate by installing a newer version of this package.
EOF
cat > "$WORK/ctl/postinst" <<'EOF'
#!/bin/sh
set -e
# Reload (not restart) so a live SSH session — including the platform's own — is never dropped.
if [ -d /run/systemd/system ]; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
fi
EOF
chmod 0755 "$WORK/ctl/postinst"
printf '/etc/ssh/talu_ca.pub\n/etc/ssh/sshd_config.d/60-talu-ca.conf\n' > "$WORK/ctl/conffiles"
( cd "$ROOT" && find . -type f -exec md5sum {} + | sed 's# \./# #' ) > "$WORK/ctl/md5sums"

# --- assemble the .deb (ar: debian-binary, control.tar.gz, data.tar.gz — in that order) --------
echo "2.0" > "$WORK/debian-binary"
tar --numeric-owner --owner=0 --group=0 -czf "$WORK/control.tar.gz" -C "$WORK/ctl" .
tar --numeric-owner --owner=0 --group=0 -czf "$WORK/data.tar.gz"    -C "$ROOT" .
OUT="$OUTDIR/talu-ca-trust_${VERSION}_all.deb"
mkdir -p "$OUTDIR"
( cd "$WORK" && ar rc "$(cd "$OUTDIR" && pwd)/talu-ca-trust_${VERSION}_all.deb" debian-binary control.tar.gz data.tar.gz )
echo "built $OUT"
echo "  trusts $(grep -c . "$CA_PUB") CA key(s); install with: apt-get install ./$(basename "$OUT")  (or via the repo)"
