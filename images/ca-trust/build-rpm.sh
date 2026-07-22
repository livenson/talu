#!/usr/bin/env bash
# Build the talu-ca-trust .rpm (bootc / CentOS-Stream side) — symmetric to build-deb.sh. rpm OWNS the
# trust file, so a CA rotation is a clean `dnf upgrade`. Needs rpmbuild (`dnf install -y rpm-build`);
# runs in the in-cluster publish Job's rocky container, or on the rpm-based lab host.
#
# Usage: build-rpm.sh <ca-pubkey-file> <version> [outdir]
set -euo pipefail
CA_PUB=${1:?usage: build-rpm.sh <ca-pubkey-file> <version> [outdir]}
VERSION=${2:?version (integer; bump on every CA change)}
OUTDIR=${3:-.}
[ -s "$CA_PUB" ] || { echo "CA pubkey '$CA_PUB' empty/missing" >&2; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"/{BUILD,RPMS,SPECS,SOURCES,BUILDROOT} "$WORK/src/etc/ssh/sshd_config.d"
install -m0644 "$CA_PUB" "$WORK/src/etc/ssh/talu_ca.pub"
cat > "$WORK/src/etc/ssh/sshd_config.d/60-talu-ca.conf" <<'EOF'
# Managed by the talu-ca-trust package — rotate by installing a newer version.
TrustedUserCAKeys /etc/ssh/talu_ca.pub
PasswordAuthentication no
EOF

cat > "$WORK/SPECS/talu-ca-trust.spec" <<EOF
Name:           talu-ca-trust
Version:        $VERSION
Release:        1
Summary:        Talu SSH User CA trust
License:        MIT
BuildArch:      noarch
%description
Installs the Pomerium SSH User CA public key(s) this cluster's VMs trust (TrustedUserCAKeys).
Rotate by installing a newer version.
%install
mkdir -p %{buildroot}/etc/ssh/sshd_config.d
install -m0644 $WORK/src/etc/ssh/talu_ca.pub %{buildroot}/etc/ssh/talu_ca.pub
install -m0644 $WORK/src/etc/ssh/sshd_config.d/60-talu-ca.conf %{buildroot}/etc/ssh/sshd_config.d/60-talu-ca.conf
%files
/etc/ssh/talu_ca.pub
/etc/ssh/sshd_config.d/60-talu-ca.conf
%post
# reload (never restart) so a live sshd session — incl. the platform's own — is not dropped.
if [ -d /run/systemd/system ]; then systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || true; fi
EOF

rpmbuild --quiet --define "_topdir $WORK" -bb "$WORK/SPECS/talu-ca-trust.spec" >/dev/null 2>&1
mkdir -p "$OUTDIR"
cp "$WORK/RPMS/noarch/talu-ca-trust-${VERSION}-1.noarch.rpm" "$OUTDIR/"
echo "built $OUTDIR/talu-ca-trust-${VERSION}-1.noarch.rpm ($(grep -c . "$CA_PUB") CA key(s))"
