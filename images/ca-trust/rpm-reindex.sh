#!/usr/bin/env bash
# Generate rpm repo metadata (repodata/) over a dir of .rpms so a guest can `dnf install` from it.
# Needs createrepo_c (`dnf install -y createrepo_c`). If a GPG key is imported (GPG_SIGN=true), the
# repomd.xml is detach-signed so guests can set repo_gpgcheck=1. Runs in the publish Job's rocky container.
#
# Usage: rpm-reindex.sh <repo-dir>     env: GPG_SIGN=true|false (default false), GPG_KEYID
set -euo pipefail
REPO=${1:?usage: rpm-reindex.sh <repo-dir>}
createrepo_c --update "$REPO" >/dev/null

if [ "${GPG_SIGN:-false}" = true ]; then
  gpg --batch --yes --detach-sign --armor ${GPG_KEYID:+--local-user "$GPG_KEYID"} "$REPO/repodata/repomd.xml"
  echo "rpm repo indexed + repomd.xml signed: $REPO"
else
  echo "rpm repo indexed (unsigned): $REPO"
fi
