#!/usr/bin/env bash
# Generate flat-apt-repo metadata (Packages, Packages.gz, Release) over a directory of .debs — so a
# guest configured with `deb [trusted=yes] http://<repo>/ ./` can install/upgrade from it.
#
# Pure shell (ar + tar + gzip + sha256sum + md5sum + stat): NO dpkg-dev/apt-utils, so it runs on the
# rpm-based lab host too. `[trusted=yes]` skips the GPG signature, but apt still checks the Release
# hashes against Packages — which we compute here — so this repo works without signing (fine for a lab;
# GPG-sign the Release for production).
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

echo "reindexed $REPO — $(grep -c '^Package:' Packages) package version(s), origin=$ORIGIN"
