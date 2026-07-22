#!/usr/bin/env bash
# Rotate the Pomerium SSH User CA with ZERO guest lockout — via DUAL-TRUST. The platform NEVER SSHes
# into a guest: trust is distributed by the `talu-ca-trust` package (running VMs auto-update it) and by
# the pomerium-user-ca ConfigMap (new VMs read it at boot). Old + new CA are both trusted during the
# window, so no cert is ever rejected while the signer switches over.
#
#   ca-rotate.sh prepare   # generate CA2; trust BOTH (ConfigMap + rebuilt package); signer STILL CA1
#   ca-rotate.sh switch    # Pomerium signs with CA2 now; guests still trust CA1+CA2 (no lockout)
#   ca-rotate.sh retire    # drop CA1: package + ConfigMap become CA2-only; guests stop trusting CA1
#   ca-rotate.sh status
#
# BETWEEN prepare→switch: roll the new package to guests (apt/dnf auto-update, or a bootc image update)
#   and let tenants re-render so new VMs get dual-trust. Verify every guest trusts BOTH before switch.
# BETWEEN switch→retire: a grace window, then confirm no CA1-signed sessions remain.
set -euo pipefail

NS=pomerium; SEC=pomerium-ssh; CM=pomerium-user-ca
REPO=${CA_REPO_DIR:-/tmp/carepo}          # where the rebuilt .deb lands (publish to your repo from here)
HERE=$(cd "$(dirname "$0")" && pwd)
export KUBECONFIG=${KUBECONFIG:-$HOME/.talu/kubeconfig}

priv() { local T; T=$(mktemp); kubectl -n $NS get secret $SEC -o jsonpath="{.data.$1}" 2>/dev/null | base64 -d > "$T"; chmod 600 "$T"; echo "$T"; }
have() { kubectl -n $NS get secret $SEC -o jsonpath="{.data.$1}" >/dev/null 2>&1 && [ -n "$(kubectl -n $NS get secret $SEC -o jsonpath="{.data.$1}")" ]; }
set_key()   { kubectl -n $NS patch secret $SEC -p "{\"data\":{\"$1\":\"$(base64 -w0 <"$2")\"}}"; }
del_key()   { kubectl -n $NS patch secret $SEC --type=json -p="[{\"op\":\"remove\",\"path\":\"/data/$1\"}]" 2>/dev/null || true; }
pub_of()    { local p; p=$(priv "$1"); ssh-keygen -y -f "$p"; rm -f "$p"; }

publish_trust() {  # $1 = pubkey file (1 or 2 keys), $2 = package version
  # New VMs read the ConfigMap at boot; running package-mode VMs auto-update from the pkg-repo.
  kubectl -n $NS create configmap $CM --from-file=user_ca.pub="$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if kubectl -n "${PKG_REPO_NS:-golden-images}" get deploy pkg-repo >/dev/null 2>&1; then
    CA_REPO_DIR="$REPO" bash "$HERE/../../images/ca-trust/publish.sh" "$2"   # build + index + push to pkg-repo
  else
    bash "$HERE/../../images/ca-trust/build-deb.sh" "$1" "$2" "$REPO/deb"
    echo "  trust: ConfigMap $CM updated + talu-ca-trust_${2}_all.deb built. (pkg-repo not deployed →"
    echo "  guests won't auto-update; deploy components/platform/pkg-repo, or bake it into the bootc image.)"
  fi
}

# Monotonically-increasing package version — stored on the ConfigMap. Hardcoded versions would make a
# SECOND rotation republish a version BELOW what guests already have, so they'd never update. (dpkg/rpm
# install the highest version.)
next_version() {
  local cur; cur=$(kubectl -n $NS get cm $CM -o jsonpath='{.metadata.annotations.talu\.io/ca-pkg-version}' 2>/dev/null)
  cur=${cur:-0}; local nxt=$(( cur + 1 ))
  kubectl -n $NS annotate cm $CM "talu.io/ca-pkg-version=$nxt" --overwrite >/dev/null 2>&1 || true
  echo "$nxt"
}

status() {
  echo "secret $SEC keys: $(kubectl -n $NS get secret $SEC -o jsonpath='{range .data}{.}{end}' >/dev/null 2>&1; kubectl -n $NS get secret $SEC -o go-template='{{range $k,$v := .data}}{{$k}} {{end}}')"
  echo "trusted CA pubkeys (ConfigMap $CM):"; kubectl -n $NS get cm $CM -o jsonpath='{.data.user_ca\.pub}' | sed 's/^/   /'
  have user_ca_next && echo "state: PREPARED (CA2 staged; run 'switch')"
  have user_ca_prev && echo "state: SWITCHED (signing with CA2; run 'retire' after the grace window)"
}

prepare() {
  have user_ca_next && { echo "already prepared (user_ca_next staged). Run 'switch' or 'retire'."; exit 1; }
  echo "== generate CA2 and stage it =="
  local T; T=$(mktemp -d); ssh-keygen -t ed25519 -N "" -f "$T/ca2" -C "Pomerium User CA (rotated)" -q
  set_key user_ca_next "$T/ca2"; rm -rf "$T"
  local ver; ver=$(next_version)
  echo "== trust BOTH CAs (ConfigMap + package v$ver); signer stays CA1 =="
  local BOTH; BOTH=$(mktemp); { pub_of user_ca; pub_of user_ca_next; } > "$BOTH"
  publish_trust "$BOTH" "$ver"; rm -f "$BOTH"
  echo "== DONE prepare. Roll the package to guests + re-render tenants, confirm all trust BOTH, then: switch =="
}

switch() {
  have user_ca_next || { echo "not prepared — run 'prepare' first." >&2; exit 1; }
  echo "== promote CA2 to the active signer (keep CA1 as user_ca_prev) =="
  local P; P=$(priv user_ca_prev 2>/dev/null || true)   # noop if absent
  priv user_ca   > /tmp/.ca1 && set_key user_ca_prev /tmp/.ca1 && rm -f /tmp/.ca1
  local N; N=$(priv user_ca_next); set_key user_ca "$N"; rm -f "$N"
  del_key user_ca_next
  [ -n "${P:-}" ] && rm -f "$P"
  echo "== restart Pomerium so it re-reads /ssh/user_ca (now CA2) =="
  kubectl -n $NS rollout restart deploy/pomerium >/dev/null
  kubectl -n $NS rollout status deploy/pomerium --timeout=120s | tail -1
  echo "== DONE switch. New SSH certs are CA2-signed; guests trust CA1+CA2. After a grace window: retire =="
}

retire() {
  have user_ca_prev || { echo "nothing to retire (not switched) — run 'switch' first." >&2; exit 1; }
  local ver; ver=$(next_version)
  echo "== trust CA2 ONLY (ConfigMap + package v$ver); drop CA1 =="
  local ONLY; ONLY=$(mktemp); pub_of user_ca > "$ONLY"
  publish_trust "$ONLY" "$ver"; rm -f "$ONLY"
  del_key user_ca_prev
  echo "== DONE retire. Roll the CA2-only package to guests; CA1 is gone. Rotation complete. =="
}

case "${1:-}" in
  prepare) prepare ;;
  switch)  switch ;;
  retire)  retire ;;
  status)  status ;;
  *) echo "usage: ca-rotate.sh {prepare|switch|retire|status}" >&2; exit 2 ;;
esac
