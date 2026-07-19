#!/usr/bin/env bash
# Detect (and with --delete, remove) orphaned Pomerium Native SSH plumbing — the Service,
# pinning policy, cloud-init Secret and ssh:// route left behind when a VM is deleted.
#
# Why orphans happen: the Pomerium ssh:// routes are rendered from every Service labelled
# `talu.io/ssh-expose=true` WITHOUT checking that the VM still exists (see expose-vm.sh). So a
# manually-exposed VM leaks its Service/policy/route when the VM is deleted, and Pomerium then
# authenticates a user and dials a backend-less ClusterIP → "no route to host". Chart-managed
# tenants do NOT orphan: Flux GCs the VM + Service + policy + route together (that's the point).
#
# Two orphan classes are detected:
#   A. a `talu.io/ssh-expose` Service whose backing VirtualMachine no longer exists
#      → its <vm>-ssh Service, <vm>-ssh-pin CNP and <vm>-userdata Secret are orphaned.
#   B. an `ssh://<vm>` route whose upstream Service (<svc>.<ns>) no longer exists
#      → the route is orphaned.
#
# --delete removes the orphan objects and surgically strips the orphan `ssh://<vm>` route
# blocks from pomerium-config — every surviving route (and the whole config head: domain, IdP,
# HTTP routes, SSH-server block) is left byte-for-byte intact, so no lab-specific values are
# needed here and no live route's policy is disturbed.
#
# Runs on the lab host (like expose-vm.sh / vm-ssh.sh), against ~/.talu/kubeconfig.
#
# Usage:
#   gc-orphans.sh            # dry-run: report orphans, change nothing
#   gc-orphans.sh --delete   # remove the orphans and re-point pomerium-config
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/.talu/kubeconfig}
POM_NS=pomerium
DELETE=false
[ "${1:-}" = "--delete" ] && DELETE=true

hr() { printf '\n== %s ==\n' "$1"; }

CFG=$(kubectl -n "$POM_NS" get cm pomerium-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)
declare -A DROP=()        # vm -> reason (union of the two orphan classes; keyed to dedupe)
ORPHAN_OBJS=()            # "ns vm svc" for class A

# ---- Class A: ssh-expose Services with no backing VirtualMachine ----------------------
hr "ssh-expose Services vs backing VM"
found_a=false
while read -r ns vm svc _; do
  [ -z "${vm:-}" ] && continue
  if kubectl -n "$ns" get vm "$vm" >/dev/null 2>&1; then
    echo "  ok     $ns/$vm ($svc)"
  else
    echo "  ORPHAN $ns/$vm ($svc + ${vm}-ssh-pin + ${vm}-userdata) — no VirtualMachine"
    ORPHAN_OBJS+=("$ns $vm $svc"); DROP["$vm"]=svc-without-vm; found_a=true
  fi
done < <(kubectl get svc -A -l talu.io/ssh-expose=true \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.spec.selector.kubevirt\.io/vm}{" "}{.metadata.name}{"\n"}{end}')
$found_a || echo "  (no object orphans)"

# ---- Class B: ssh:// routes with no upstream Service ---------------------------------
hr "Pomerium ssh:// routes vs upstream Service"
found_b=false
while read -r vm svc ns; do
  [ -z "${vm:-}" ] && continue
  if kubectl -n "$ns" get svc "$svc" >/dev/null 2>&1; then
    echo "  ok     ssh://$vm -> $svc.$ns"
  else
    echo "  ORPHAN ssh://$vm -> $svc.$ns — upstream Service missing"
    DROP["$vm"]=route-without-svc; found_b=true
  fi
done < <(awk '
  /^[[:space:]]*- from: ssh:\/\// { vm=$0; sub(/.*ssh:\/\//,"",vm); next }
  /^[[:space:]]*to: ssh:\/\// && vm!="" {
    to=$0; sub(/.*ssh:\/\//,"",to); sub(/\.svc.*/,"",to);
    split(to,a,"."); print vm, a[1], a[2]; vm="" }' <<<"$CFG")
$found_b || echo "  (no route orphans)"

if [ ${#DROP[@]} -eq 0 ]; then hr "result"; echo "no orphans found."; exit 0; fi

if ! $DELETE; then
  hr "dry-run"; echo "orphans: ${!DROP[*]}"; echo "re-run with --delete to remove them."; exit 0
fi

# ---- delete orphan objects (class A) --------------------------------------------------
if [ ${#ORPHAN_OBJS[@]} -gt 0 ]; then
  hr "deleting orphan objects"
  for row in "${ORPHAN_OBJS[@]}"; do
    read -r ns vm svc <<<"$row"
    kubectl -n "$ns" delete svc "$svc" --ignore-not-found
    kubectl -n "$ns" delete ciliumnetworkpolicy "${vm}-ssh-pin" --ignore-not-found
    kubectl -n "$ns" delete secret "${vm}-userdata" --ignore-not-found
  done
fi

# ---- strip orphan ssh:// route blocks from pomerium-config (surgical, format-preserving)
hr "removing orphan ssh:// routes from pomerium-config"
DROPRE="^($(IFS='|'; echo "${!DROP[*]}"))$"
NEWCFG=$(awk -v drop="$DROPRE" '
  /^[[:space:]]*- from: / {                 # a route block starts here
    if ($0 ~ /ssh:\/\//) { v=$0; sub(/.*ssh:\/\//,"",v); skip=(v~drop)?1:0 }
    else skip=0                              # http route → always keep
  }
  { if (!skip) print }' <<<"$CFG")

kubectl -n "$POM_NS" create configmap pomerium-config --from-literal=config.yaml="$NEWCFG" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$POM_NS" rollout restart deploy/pomerium >/dev/null
kubectl -n "$POM_NS" rollout status deploy/pomerium --timeout=120s | tail -1

hr "done"; echo "removed ${#DROP[@]} orphan(s): ${!DROP[*]}"
