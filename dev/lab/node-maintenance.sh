#!/usr/bin/env bash
# Safely take a node in/out of maintenance, live-migrating its VMs first (KubeVirt-aware drain).
#
# KubeVirt's evacuation controller live-migrates every VMI that has an evictionStrategy (the cluster
# default LiveMigrate, set by the kubevirt role) when it sees the kubevirt.io/drain taint — instead of
# the VM being shut off. An auto-created PodDisruptionBudget per VMI blocks eviction until migration is
# done. This script applies that taint, waits for the node to empty of VMIs, then finishes the drain.
#
# Usage:
#   node-maintenance.sh drain    <node>      # cordon + taint + wait migrations + drain
#   node-maintenance.sh uncordon <node>      # un-taint + uncordon (back into service)
#   node-maintenance.sh status   [<node>]    # show nodes + where VMIs run
#
# SINGLE-NODE GUARD: if there is no other schedulable node to migrate onto, this REFUSES to evacuate
# (there's nowhere to go) — it warns, drains only non-VM pods, and never silently powers a VM off.
set -euo pipefail

export KUBECONFIG=${KUBECONFIG:-$HOME/.talu/kubeconfig}
DRAIN_TAINT="kubevirt.io/drain=draining:NoSchedule"
WAIT_TIMEOUT=${WAIT_TIMEOUT:-600}   # seconds to wait for migrations to finish

vmis_on_node() {  # list "<ns>/<name>" of VMIs currently on $1
  kubectl get vmi -A -o jsonpath="{range .items[?(@.status.nodeName==\"$1\")]}{.metadata.namespace}/{.metadata.name}{'\n'}{end}" 2>/dev/null
}

other_schedulable_nodes() {  # Ready, schedulable nodes that are NOT $1
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.unschedulable}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
    | awk -v self="$1" '$1!=self && $2!="true" && $3=="True" {print $1}'
}

status() {
  echo "== nodes =="; kubectl get nodes -o wide
  echo "== VMIs by node =="
  kubectl get vmi -A -o custom-columns='NAMESPACE:.metadata.namespace,VMI:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase' 2>/dev/null || echo "  (no VMIs)"
}

drain() {
  local node=$1
  kubectl get node "$node" >/dev/null   # errors out if the node doesn't exist

  local targets; targets=$(other_schedulable_nodes "$node")

  # No other schedulable node → effectively single-node: nothing can be evacuated (VMs can't migrate,
  # pods can't reschedule). Draining here would only STRAND pods, so cordon + warn and stop — never
  # power a VM off or evict pods with nowhere to go. On real hardware there's a target and we proceed.
  if [ -z "$targets" ]; then
    echo "!! No other schedulable node — this is effectively a single-node cluster."
    echo "!! Nothing can be evacuated; NOT draining (it would only strand pods). Cordoning only —"
    echo "!! maintenance here means downtime. On multi-node hardware this live-migrates + drains cleanly."
    kubectl cordon "$node"
    local on_node; on_node=$(vmis_on_node "$node")
    [ -n "$on_node" ] && { echo "   VMs left running on $node:"; echo "$on_node" | sed 's/^/     /'; }
    echo "== $node cordoned. Run 'uncordon $node' when maintenance is done. =="
    return 0
  fi

  echo "== cordon $node =="
  kubectl cordon "$node"

  echo "== taint $node ($DRAIN_TAINT) → KubeVirt live-migrates its VMIs =="
  kubectl taint node "$node" "$DRAIN_TAINT" --overwrite

  echo "== waiting up to ${WAIT_TIMEOUT}s for VMIs to migrate off $node =="
  local deadline=$(( SECONDS + WAIT_TIMEOUT )) on_node
  while :; do
    on_node=$(vmis_on_node "$node")
    [ -z "$on_node" ] && { echo "   all VMIs migrated off $node."; break; }
    local n; n=$(printf '%s\n' "$on_node" | grep -c '/')
    echo "   $n VMI(s) still on $node; active migrations:"
    kubectl get virtualmachineinstancemigration -A --no-headers 2>/dev/null \
      | awk '$0 !~ /Succeeded/ {print "     "$0}' | head -5 || true
    [ "$SECONDS" -ge "$deadline" ] && { echo "!! timed out waiting for migrations; not force-draining VMs. Investigate."; exit 1; }
    sleep 10
  done

  echo "== drain remaining (non-VM) pods off $node =="
  kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force
  echo "== $node drained and ready for maintenance. Run 'uncordon $node' afterwards. =="
}

uncordon() {
  local node=$1
  kubectl get node "$node" >/dev/null
  echo "== remove drain taint + uncordon $node =="
  kubectl taint node "$node" kubevirt.io/drain- 2>/dev/null || true
  kubectl uncordon "$node"
  echo "== $node back in service. =="
}

case "${1:-}" in
  drain)    [ -n "${2:-}" ] || { echo "usage: node-maintenance.sh drain <node>" >&2; exit 2; }; drain "$2" ;;
  uncordon) [ -n "${2:-}" ] || { echo "usage: node-maintenance.sh uncordon <node>" >&2; exit 2; }; uncordon "$2" ;;
  status)   status ;;
  *) echo "usage: node-maintenance.sh {drain|uncordon} <node> | status" >&2; exit 2 ;;
esac
