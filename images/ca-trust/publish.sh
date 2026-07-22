#!/usr/bin/env bash
# Build the talu-ca-trust package(s) from the CURRENT CA pubkey (pomerium-user-ca ConfigMap), index the
# repo(s), optionally GPG-sign, and publish to the in-cluster pkg-repo. Produces:
#   - deb (always; pure-shell build)          → $REPO/deb   served at .../deb/
#   - rpm (if rpmbuild + createrepo_c present) → $REPO/rpm   served at .../rpm/
#   - the signing pubkey (if GPG_SIGN=true)    → $REPO/talu-ca.asc
# Accumulates versions (apt/dnf install the highest). bootc guests get the rpm baked into the image.
#
# Usage: publish.sh <version>
#   env: CA_REPO_DIR (default /tmp/carepo), PKG_REPO_NS (golden-images),
#        GPG_SIGN (true|false, default false), GPG_KEYID, GPG_KEY_FILE (ascii-armored private key to import)
# On the lab this builds host-side + `kubectl cp`s in; in production it IS the in-cluster publish Job
# (components/platform/pkg-repo/publish-job.yaml) running these same steps against the PVC.
set -euo pipefail
VER=${1:?usage: publish.sh <version>}
NS=${PKG_REPO_NS:-golden-images}
BASE=${CA_REPO_DIR:-/tmp/carepo}
HERE=$(cd "$(dirname "$0")" && pwd)
# `-` (not `:-`): unset → default file; empty (KUBECONFIG="" in the in-cluster Job) → kubectl uses the
# pod's ServiceAccount (in-cluster config).
export KUBECONFIG=${KUBECONFIG-$HOME/.talu/kubeconfig}
export GPG_SIGN=${GPG_SIGN:-false}

# import the signing key if provided (Job mounts it from a Secret; host may pass a file)
if [ "$GPG_SIGN" = true ] && [ -n "${GPG_KEY_FILE:-}" ]; then gpg --batch --import "$GPG_KEY_FILE" 2>/dev/null || true; fi

mkdir -p "$BASE/deb"
kubectl -n pomerium get cm pomerium-user-ca -o jsonpath='{.data.user_ca\.pub}' > "$BASE/ca.pub"

# --- deb (always) ---
bash "$HERE/build-deb.sh"  "$BASE/ca.pub" "$VER" "$BASE/deb"
bash "$HERE/apt-reindex.sh" "$BASE/deb"

# --- rpm (when the toolchain is present — e.g. the Job's rocky container, or the rpm-based lab host) ---
if command -v rpmbuild >/dev/null && command -v createrepo_c >/dev/null; then
  mkdir -p "$BASE/rpm"
  bash "$HERE/build-rpm.sh"  "$BASE/ca.pub" "$VER" "$BASE/rpm"
  bash "$HERE/rpm-reindex.sh" "$BASE/rpm"
else
  echo "  (rpmbuild/createrepo_c not found — skipping rpm; bootc guests need it. Run in the publish Job.)"
fi
rm -f "$BASE/ca.pub"

# --- publish the signing pubkey so guests can pin it ---
if [ "$GPG_SIGN" = true ]; then gpg --batch --armor --export ${GPG_KEYID:+"$GPG_KEYID"} > "$BASE/talu-ca.asc"; fi

# --- sync to the pkg-repo PVC ---
POD=$(kubectl -n "$NS" get pod -l app=pkg-repo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$POD" ] || { echo "!! pkg-repo pod not found in $NS — deploy components/platform/pkg-repo." >&2; exit 1; }
echo "== sync $BASE → $NS/$POD:/srv/repo =="
kubectl -n "$NS" exec "$POD" -- mkdir -p /srv/repo/deb /srv/repo/rpm
tar -C "$BASE" -cf - . | kubectl -n "$NS" exec -i "$POD" -- tar -C /srv/repo -xf -
echo "== published talu-ca-trust v$VER → http://pkg-repo.$NS.svc/{deb,rpm}/  (signed=$GPG_SIGN) =="
