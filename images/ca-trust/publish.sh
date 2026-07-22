#!/usr/bin/env bash
# Build the talu-ca-trust package from the CURRENT CA pubkey (the pomerium-user-ca ConfigMap) and
# publish it to the in-cluster pkg-repo, so mutable guests auto-update. Accumulates versions in
# $CA_REPO_DIR (apt installs the highest). bootc guests get the package via the image, not this repo.
#
# Usage: publish.sh <version>        env: CA_REPO_DIR (default /tmp/carepo), PKG_REPO_NS (golden-images)
# On the lab this builds on the host + `kubectl cp`s into the repo pod; in production, run the same steps
# as an in-cluster Job (reads the ConfigMap, writes the pkg-repo PVC) — see images/ca-trust/README.md.
set -euo pipefail
VER=${1:?usage: publish.sh <version>}
NS=${PKG_REPO_NS:-golden-images}
REPO=${CA_REPO_DIR:-/tmp/carepo}/deb
HERE=$(cd "$(dirname "$0")" && pwd)
export KUBECONFIG=${KUBECONFIG:-$HOME/.talu/kubeconfig}

mkdir -p "$REPO"
kubectl -n pomerium get cm pomerium-user-ca -o jsonpath='{.data.user_ca\.pub}' > "$REPO/ca.pub"
bash "$HERE/build-deb.sh" "$REPO/ca.pub" "$VER" "$REPO"; rm -f "$REPO/ca.pub"
bash "$HERE/apt-reindex.sh" "$REPO"

POD=$(kubectl -n "$NS" get pod -l app=pkg-repo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$POD" ] || { echo "!! pkg-repo pod not found in $NS — deploy components/platform/pkg-repo to distribute." >&2; exit 1; }
echo "== sync $REPO → $NS/$POD:/srv/repo/deb =="
kubectl -n "$NS" exec "$POD" -- mkdir -p /srv/repo/deb
for f in "$REPO"/*; do
  [ -f "$f" ] && kubectl cp "$f" "$NS/$POD:/srv/repo/deb/$(basename "$f")"
done
echo "== published talu-ca-trust v$VER → deb [trusted=yes] http://pkg-repo.$NS.svc/deb/ ./ =="
