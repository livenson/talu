#!/usr/bin/env bash
# Generate flat-apt-repo metadata (Packages, Packages.gz, Release) over a directory of .debs — so a
# guest configured with `deb [trusted=yes] http://<repo>/ ./` can install/upgrade from it.
#
# Pure shell (ar + tar + gzip + sha256sum + md5sum + stat): NO dpkg-dev/apt-utils, so it runs on the
# rpm-based lab host too. With GPG_SIGN=true it also writes InRelease + Release.gpg (production); without
# it, `[trusted=yes]` skips the signature and apt still checks the Release hashes we compute here.
#
# Usage: apt-reindex.sh <repo-dir> [origin]     env: GPG_SIGN=true|false (default false), GPG_KEYID
set -euo pipefail
REPO=${1:?usage: apt-reindex.sh <repo-dir>}
ORIGIN=${2:-talu}                 # Release Origin — match it in unattended-upgrades Origins-Pattern
cd "$REPO"

: > Packages
for deb in *.deb; do
  [ -e "$deb" ] || { echo "no .deb in $REPO" >&2; exit 1; }
  ar p "$deb" control.tar.gz | tar xzO ./control 2>/dev/null | sed -e 's/[[:space:]]*$//' -e '/^$/d' >> Packages
  {
    printf 'Filename: %s\n' "$deb"
    printf 'Size: %s\n'     "$(stat -c%s "$deb")"
    printf 'MD5sum: %s\n'   "$(md5sum "$deb"    | cut -d' ' -f1)"
    printf 'SHA256: %s\n\n' "$(sha256sum "$deb" | cut -d' ' -f1)"
  } >> Packages
done
gzip -9kf Packages

hashline() { printf ' %s %16s %s\n' "$(sha256sum "$1" | cut -d' ' -f1)" "$(stat -c%s "$1")" "$1"; }
{
  echo "Origin: $ORIGIN"
  echo "Label: talu-ca-trust"
  echo "Suite: stable"
  echo "Architectures: all"
  echo "Date: $(date -Ru)"
  echo "SHA256:"
  hashline Packages
  hashline Packages.gz
} > Release

if [ "${GPG_SIGN:-false}" = true ]; then
  # InRelease (inline-signed) + Release.gpg (detached) — apt verifies against the pinned pubkey, so
  # guests drop `trusted=yes` and use `signed-by=/etc/apt/keyrings/talu-ca.gpg` instead.
  rm -f InRelease Release.gpg
  gpg --batch --yes ${GPG_KEYID:+--local-user "$GPG_KEYID"} --clearsign -o InRelease Release
  gpg --batch --yes ${GPG_KEYID:+--local-user "$GPG_KEYID"} -abs   -o Release.gpg Release
  echo "reindexed + SIGNED $REPO — $(grep -c '^Package:' Packages) version(s), origin=$ORIGIN"
else
  echo "reindexed $REPO — $(grep -c '^Package:' Packages) package version(s), origin=$ORIGIN (unsigned)"
fi
