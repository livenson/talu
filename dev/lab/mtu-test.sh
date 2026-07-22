#!/usr/bin/env bash
# Stage 1 exit criterion: prove pod-to-pod networking carries large payloads under the
# host's mandated MTU (the subtle failure mode of this hosting). A wrong pod MTU silently
# blackholes large TCP frames while small ones pass — so we test BOTH a DF-ping near the
# MTU and a bulk TCP transfer. Runs LOCALLY against the tunnel.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/env.sh"
export KUBECONFIG="$LAB_KUBECONFIG"
NS=mtu-test
IMG="${MTU_TEST_IMAGE:-nicolaka/netshoot:latest}"

cleanup() { kubectl delete ns "$NS" --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

kubectl create ns "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
for p in a b; do
  kubectl -n "$NS" run "pod-$p" --image="$IMG" --restart=Never --command -- sleep 3600 >/dev/null 2>&1 || true
done
echo "mtu-test: waiting for pods..."
kubectl -n "$NS" wait --for=condition=Ready pod/pod-a pod/pod-b --timeout=120s

IP_B=$(kubectl -n "$NS" get pod pod-b -o jsonpath='{.status.podIP}')
echo "mtu-test: pod-b at $IP_B"

# 1) DF ping near the MTU (payload 1322 = 1350 - 28 for IP+ICMP headers). Must PASS.
echo "== DF ping, 1322-byte payload (must pass) =="
# shellcheck disable=SC1010  # `-M do` is ping's PMTU-discovery mode, not a shell 'do' keyword
kubectl -n "$NS" exec pod-a -- ping -c 3 -M do -s 1322 "$IP_B"

# 2) Bulk TCP transfer — the real large-payload signal (catches silent MTU blackholes).
echo "== bulk TCP transfer via iperf3 =="
kubectl -n "$NS" exec pod-b -- sh -c 'iperf3 -s -1 -D' >/dev/null 2>&1 || \
  kubectl -n "$NS" exec pod-b -- sh -c 'nohup iperf3 -s -1 >/tmp/ip.log 2>&1 &'
sleep 2
kubectl -n "$NS" exec pod-a -- iperf3 -c "$IP_B" -t 5 -P 4

echo
echo "mtu-test: PASS — large payloads traverse pod-to-pod under MTU. Stage 1 network gate met."
