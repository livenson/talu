#!/usr/bin/env bash
# Expose a VM for Pomerium Native SSH — label-driven plumbing (no OpenBao, no tunnel).
#
# Per VM it creates:   Service <vm>-ssh (kubevirt.io/vm selector, :22)
#                      CiliumNetworkPolicy <vm>-ssh-pin (ingress only from Pomerium ns)
# Then it RE-RENDERS the Pomerium config from every Service labelled talu.io/ssh-expose=true:
# base HTTP routes + the SSH-server block (User CA + host keys) + one ssh://<vm> route each.
# Idempotent, safe to run for several VMs. Mirrors what the tenant-chart does in production.
#
# Users then log in with stock ssh:   ssh <principal>@<vm>@ssh.<domain> -p <SSH_PORT>
#
# Usage:  expose-vm.sh <vm> <namespace>
#   env: LAB_DOMAIN (203-0-113-10.sslip.io), SSH_PORT (23), ALLOWED_USERS (alice@talu.local)
set -euo pipefail

VM=${1:?usage: expose-vm.sh <vm> <namespace>}
NS=${2:?namespace}
export KUBECONFIG=${KUBECONFIG:-$HOME/.talu/kubeconfig}
DOMAIN=${LAB_DOMAIN:-203-0-113-10.sslip.io}
POM_NS=pomerium
SSH_PORT=${SSH_PORT:-23}
ALLOWED_USERS=${ALLOWED_USERS:-alice@talu.local}

echo "== 1. per-VM Service + Cilium pinning policy (ns=$NS vm=$VM) =="
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${VM}-ssh
  namespace: ${NS}
  labels: { talu.io/ssh-expose: "true", talu.io/vm: "${VM}" }
  # per-VM allow-list (annotation, not label: emails contain '@' which labels reject)
  annotations: { talu.io/allowed-users: "${ALLOWED_USERS}" }
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

echo "== 2. re-render Pomerium config (base HTTP + SSH server + ssh://<vm> per label) =="
CFG="
autocert: true
autocert_dir: /data/autocert
metrics_address: \":9902\"
authenticate_service_url: https://authenticate.${DOMAIN}
idp_provider: oidc
idp_provider_url: https://id.${DOMAIN}/dex
idp_client_id: pomerium
idp_client_secret: pomerium-secret-lab
idp_scopes: [openid, profile, email]
ssh_address: \":2222\"
ssh_user_ca_key_file: /ssh/user_ca
ssh_host_key_files: [/ssh/host_ed25519, /ssh/host_rsa, /ssh/host_ecdsa]
routes:
  - from: https://id.${DOMAIN}
    to: http://dex.identity.svc:5556
    allow_public_unauthenticated_access: true
    preserve_host_header: true
  - from: https://whoami.${DOMAIN}
    to: http://whoami.pomerium.svc:80
    allowed_users: [${ALLOWED_USERS}]
  - from: https://vms.${DOMAIN}
    to: http://kubevirt-manager.kubevirt-manager.svc.cluster.local:8080
    allowed_users: [${ALLOWED_USERS}]
    allow_websockets: true
  - from: https://perses.${DOMAIN}
    to: http://talu.monitoring.svc.cluster.local:8080
    allowed_users: [${ALLOWED_USERS}]
    allow_websockets: true
  - from: https://hubble.${DOMAIN}
    to: http://hubble-ui.kube-system.svc.cluster.local:80
    allowed_users: [${ALLOWED_USERS}]
    allow_websockets: true
  - from: https://alertmanager.${DOMAIN}
    to: http://kube-prometheus-stack-alertmanager.monitoring.svc.cluster.local:9093
    allowed_users: [${ALLOWED_USERS}]
    allow_websockets: true
"
# one ssh:// route per exposed VM (declarative). Each route's allow-list comes from the
# Service's talu.io/allowed-users annotation (per-tenant policy), not a global default.
while read -r vm svc ns au _; do
  [ -z "$vm" ] && continue
  au=${au:-$ALLOWED_USERS}
  CFG="${CFG}
  - from: ssh://${vm}
    to: ssh://${svc}.${ns}.svc.cluster.local:22
    policy:
      - allow:
          and:
            - email:
                in: [${au}]"
done < <(kubectl get svc -A -l talu.io/ssh-expose=true \
           -o jsonpath='{range .items[*]}{.metadata.labels.talu\.io/vm}{" "}{.metadata.name}{" "}{.metadata.namespace}{" "}{.metadata.annotations.talu\.io/allowed-users}{"\n"}{end}')

# one https://<ns>-dashboard route per talu.io/dashboard-expose Service (the tenant's Perses).
while read -r svc ns au _; do
  [ -z "$svc" ] && continue
  au=${au:-$ALLOWED_USERS}
  CFG="${CFG}
  - from: https://${ns}-dashboard.${DOMAIN}
    to: http://${svc}.${ns}.svc.cluster.local:8080
    allowed_users: [${au}]
    allow_websockets: true"
done < <(kubectl get svc -A -l talu.io/dashboard-expose=true \
           -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{" "}{.metadata.annotations.talu\.io/allowed-users}{"\n"}{end}')

# optional apex landing page: one public route on https://<domain> per talu.io/landing-expose Service
# (the route portal, components/platform/portal). Absent unless that component is deployed.
while read -r svc ns _; do
  [ -z "$svc" ] && continue
  CFG="${CFG}
  - from: https://${DOMAIN}
    to: http://${svc}.${ns}.svc.cluster.local:80
    allow_public_unauthenticated_access: true"
done < <(kubectl get svc -A -l talu.io/landing-expose=true \
           -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.namespace}{"\n"}{end}')

kubectl -n "$POM_NS" create configmap pomerium-config --from-literal=config.yaml="$CFG" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "$POM_NS" rollout restart deploy/pomerium >/dev/null
kubectl -n "$POM_NS" rollout status deploy/pomerium --timeout=120s | tail -1

echo
echo "Now log in:   ssh ${PRINCIPAL:-talu}@${VM}@ssh.${DOMAIN} -p ${SSH_PORT}"
