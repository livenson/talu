#!/usr/bin/env bash
# Import the lab's internal dev CA (the `talu-ca` cert-manager ClusterIssuer root, Secret talu-ca-tls in
# cert-manager) into your local OS trust store, so browsers/curl don't warn on services that present a
# talu-ca-signed cert. Pomerium's PUBLIC routes use autocert (Let's Encrypt) and are already trusted —
# this is for cluster-internal TLS surfaced to the laptop.
#
#   dev/lab/trust.sh add       # fetch the CA over SSH and add it to the OS trust store (idempotent)
#   dev/lab/trust.sh remove    # remove it again
#   dev/lab/trust.sh show      # print the CA (PEM) without installing
#
# macOS: adds to the login keychain (no sudo). Linux: installs to the system anchors (needs sudo).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/env.sh"

CA_NS=cert-manager
CA_SECRET=talu-ca-tls
CA_NAME="Talu dev CA (${LAB_SSH##*@})"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CRT="$WORK/talu-ca.crt"

fetch() {
  # Pull the CA cert from the lab. cert-manager CA secrets carry the root in ca.crt (fallback tls.crt).
  ssh "$LAB_SSH" "export KUBECONFIG=~/.talu/kubeconfig; \
    kubectl -n $CA_NS get secret $CA_SECRET -o jsonpath='{.data.ca\.crt}' 2>/dev/null \
    || kubectl -n $CA_NS get secret $CA_SECRET -o jsonpath='{.data.tls\.crt}'" \
    | base64 -d > "$CRT"
  [ -s "$CRT" ] || { echo "trust: could not fetch $CA_NS/$CA_SECRET from the lab" >&2; exit 1; }
}

add() {
  fetch
  case "$(uname -s)" in
    Darwin)
      # -r trustRoot into the login keychain; re-adding the same cert is a no-op update.
      security add-trusted-cert -r trustRoot -k "$HOME/Library/Keychains/login.keychain-db" "$CRT"
      echo "trust: added '$CA_NAME' to the macOS login keychain."
      ;;
    Linux)
      if [ -d /etc/pki/ca-trust/source/anchors ]; then          # Fedora/Rocky/RHEL
        sudo cp "$CRT" /etc/pki/ca-trust/source/anchors/talu-ca.crt && sudo update-ca-trust
      elif [ -d /usr/local/share/ca-certificates ]; then        # Debian/Ubuntu
        sudo cp "$CRT" /usr/local/share/ca-certificates/talu-ca.crt && sudo update-ca-certificates
      else
        echo "trust: unknown Linux trust store — cert is at $CRT (copy it manually)" >&2; exit 1
      fi
      echo "trust: added the Talu dev CA to the system trust store."
      ;;
    *) echo "trust: unsupported OS $(uname -s)" >&2; exit 1 ;;
  esac
  echo "trust: restart your browser to pick up the new root."
}

remove() {
  case "$(uname -s)" in
    Darwin)
      fetch
      cn=$(openssl x509 -in "$CRT" -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/ *commonName *= *//p')
      # delete by common name; harmless if absent.
      security delete-certificate -c "$cn" "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null \
        || echo "trust: no matching cert in the login keychain (already removed?)"
      ;;
    Linux)
      sudo rm -f /etc/pki/ca-trust/source/anchors/talu-ca.crt /usr/local/share/ca-certificates/talu-ca.crt
      command -v update-ca-trust >/dev/null && sudo update-ca-trust || sudo update-ca-certificates
      echo "trust: removed the Talu dev CA."
      ;;
  esac
}

case "${1:-add}" in
  add) add ;;
  remove) remove ;;
  show) fetch; openssl x509 -in "$CRT" -noout -subject -issuer -dates 2>/dev/null; cat "$CRT" ;;
  *) echo "usage: $0 {add|remove|show}" >&2; exit 2 ;;
esac
