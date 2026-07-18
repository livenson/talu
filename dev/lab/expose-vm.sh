#!/usr/bin/env bash
# Expose a VM for OpenBao-cert SSH through Pomerium — the generalized, label-driven plumbing.
#
# Per VM it creates:   Service <vm>-ssh (kubevirt.io/vm selector, :22)
#                      CiliumNetworkPolicy <vm>-ssh-pin (ingress only from Pomerium ns)
# Then it RE-RENDERS the Pomerium route list from every Service labelled
# talu.io/ssh-expose=true (base routes + one tcp route per exposed VM) and opens the
# OIDC-gated tunnel. Idempotent — re-runnable, and safe to run for several VMs.
#
# This mirrors what the Talu tenant-chart does in production (chart = source of truth,
# every object stamped talu.io/project-uuid); here a script stands in for the chart.
#
# Usage:  expose-vm.sh <vm> <namespace>
#   env: LAB_DOMAIN (default 203-0-113-10.sslip.io)
set -euo pipefail

VM=${1:?usage: expose-vm.sh <vm> <namespace>}
NS=${2:?namespace}
export KUBECONFIG=${KUBECONFIG:-$HOME/.talu/kubeconfig}
DOMAIN=${LAB_DOMAIN:-203-0-113-10.sslip.io}
POM_NS=pomerium
PORT=$(( 2200 + $(printf '%s' "$VM" | cksum | cut -d' ' -f1) % 300 ))

echo "== 1. per-VM Service + Cilium pinning policy (ns=$NS vm=$VM) =="
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${VM}-ssh
  namespace: ${NS}
  labels: { talu.io/ssh-expose: "true", talu.io/vm: "${VM}" }
spec:
  selector: { kubevirt.io/vm: ${VM} }
  ports: [{ name: ssh, port: 22, targetPort: 22 }]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: ${VM}-ssh-pin, namespace: ${NS} }
spec:
  endpointSelector: { matchLabels: { kubevirt.io/vm: ${VM} } }
  ingress:
    - fromEndpoints:
        - matchLabels: { k8s:io.kubernetes.pod.namespace: ${POM_NS} }
      toPorts: [{ ports: [{ port: "22", protocol: TCP }] }]
EOF

echo "== 2. re-render Pomerium routes from all talu.io/ssh-expose Services =="
# base (HTTP) routes
CFG="
autocert: true
autocert_dir: /data/autocert
authenticate_service_url: https://authenticate.${DOMAIN}
idp_provider: oidc
idp_provider_url: https://id.${DOMAIN}/dex
idp_client_id: pomerium
idp_client_secret: pomerium-secret-lab
idp_scopes: [openid, profile, email]
routes:
  - from: https://id.${DOMAIN}
    to: http://dex.identity.svc:5556
    allow_public_unauthenticated_access: true
    preserve_host_header: true
  - from: https://whoami.${DOMAIN}
    to: http://whoami.pomerium.svc:80
    allowed_users: [alice@talu.local]
  - from: https://vms.${DOMAIN}
    to: http://kubevirt-manager.kubevirt-manager.svc.cluster.local:8080
    allowed_users: [alice@talu.local]
    allow_websockets: true"
# one tcp route per exposed VM (declarative from labels)
while read -r vm svc ns _; do
  [ -z "$vm" ] && continue
  CFG="${CFG}
  - from: tcp+https://ssh-${vm}.${DOMAIN}:22
    to: tcp://${svc}.${ns}.svc.cluster.local:22
    allowed_users: [alice@talu.local]"
done < <(kubectl get svc -A -l talu.io/ssh-expose=true \
           -o jsonpath='{range .items[*]}{.metadata.labels.talu\.io/vm}{" "}{.metadata.name}{" "}{.metadata.namespace}{"\n"}{end}')

kubectl -n "$POM_NS" create configmap pomerium-config --from-literal=config.yaml="$CFG" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$POM_NS" rollout restart deploy/pomerium >/dev/null
kubectl -n "$POM_NS" rollout status deploy/pomerium --timeout=120s | tail -1

echo "== 3. open the OIDC-gated Pomerium tunnel for ${VM} on :${PORT} =="
systemctl --user stop "talu-tunnel-${VM}" 2>/dev/null || true
if systemd-run --user --unit="talu-tunnel-${VM}" --collect \
     /usr/local/bin/pomerium-cli tcp "ssh-${VM}.${DOMAIN}:22" \
     --listen "127.0.0.1:${PORT}" --browser-cmd /tmp/hlogin.sh --disable-tls-verification 2>/dev/null; then
  echo "tunnel up (systemd --user unit talu-tunnel-${VM})"
else
  echo "start the tunnel manually:" >&2
  echo "  pomerium-cli tcp ssh-${VM}.${DOMAIN}:22 --listen 127.0.0.1:${PORT} --browser-cmd /tmp/hlogin.sh --disable-tls-verification &" >&2
fi

echo
echo "Now log in with OpenBao:   ./vm-ssh.sh ${VM} <principal>"
