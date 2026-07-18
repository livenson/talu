#!/usr/bin/env bash
# Generate the manifest bundle for one SSH-accessible Talu VM — PURE OUTPUT, no cluster mutation.
#
# Intended to be driven by an external orchestrator (Waldur): Talu's stable surface is
# "write labelled Kubernetes objects" (integration contract §10), so this emits exactly
# those objects. Every object carries talu.io/project-uuid — the join key Waldur reconciles on.
#
# Three kinds of artifact, because they live in three systems:
#   - K8s objects  (Namespace, VirtualMachine, Service, CiliumNetworkPolicy)  -> kubectl apply
#   - Pomerium route fragment                                                 -> merge into Pomerium config
#   - OpenBao role payload (JSON)                                             -> bao write ssh/roles/<vm> -
#
# Usage:
#   gen-vm-manifests.sh <vm> <namespace> [principal] > bundle.yaml     # K8s to stdout, companions to stderr
#   gen-vm-manifests.sh <vm> <namespace> [principal] -o outdir/        # all three as files
#
# Inputs (env; flags/positional override):
#   PROJECT_UUID  talu.io/project-uuid       (default: all-zero placeholder — Waldur sets the real one)
#   VM_IMAGE      containerDisk image        (default: quay.io/containerdisks/ubuntu:24.04 — OpenSSH, validates certs)
#   VM_MEMORY     guest memory              (default: 1536Mi)
#   LAB_DOMAIN    external domain            (default: 203-0-113-10.sslip.io)
#   POM_NS        Pomerium namespace         (default: pomerium)
#   ALLOWED_USERS Pomerium route allow-list  (default: alice@talu.local)
#   CA_PUBKEY     OpenBao SSH CA public key  (default: fetched from OpenBao via kubectl if reachable)
set -euo pipefail

VM=${1:?usage: gen-vm-manifests.sh <vm> <namespace> [principal] [-o dir]}
NS=${2:?namespace}
PRINCIPAL=talu; OUTDIR=""
shift 2
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUTDIR=${2:?}; shift 2 ;;
    *)  PRINCIPAL=$1; shift ;;
  esac
done

PROJECT_UUID=${PROJECT_UUID:-00000000-0000-0000-0000-000000000000}
VM_IMAGE=${VM_IMAGE:-quay.io/containerdisks/ubuntu:24.04}
VM_MEMORY=${VM_MEMORY:-1536Mi}
LAB_DOMAIN=${LAB_DOMAIN:-203-0-113-10.sslip.io}
POM_NS=${POM_NS:-pomerium}
ALLOWED_USERS=${ALLOWED_USERS:-alice@talu.local}

# CA pubkey: explicit CA_PUBKEY wins; else best-effort fetch from OpenBao (stays pure output either way).
if [ -z "${CA_PUBKEY:-}" ] && command -v kubectl >/dev/null 2>&1; then
  CA_PUBKEY=$(kubectl -n openbao exec deploy/openbao -- sh -c \
    'export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=root; bao read -field=public_key ssh/config/ca' 2>/dev/null || true)
fi
[ -n "${CA_PUBKEY:-}" ] || { echo "ERROR: set CA_PUBKEY (OpenBao ssh/config/ca public_key)" >&2; exit 1; }

k8s_bundle() {
cat <<YAML
# Talu VM bundle — vm=${VM} ns=${NS} project=${PROJECT_UUID}. Generated; do not hand-edit.
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
  labels:
    # virt-launcher needs NET_ADMIN -> violates PSA baseline; VM namespaces run privileged.
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/warn: privileged
    pod-security.kubernetes.io/audit: privileged
    talu.io/project-uuid: "${PROJECT_UUID}"
---
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM}
  namespace: ${NS}
  labels:
    talu.io/vm: "${VM}"
    talu.io/project-uuid: "${PROJECT_UUID}"
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        kubevirt.io/vm: ${VM}
        talu.io/project-uuid: "${PROJECT_UUID}"
    spec:
      domain:
        devices:
          disks:
            - { name: containerdisk, disk: { bus: virtio } }
            - { name: cloudinit, disk: { bus: virtio } }
          interfaces: [{ name: default, masquerade: {} }]
        resources: { requests: { memory: ${VM_MEMORY} } }
      networks: [{ name: default, pod: {} }]
      volumes:
        - name: containerdisk
          containerDisk: { image: ${VM_IMAGE} }
        - name: cloudinit
          cloudInitNoCloud:
            userData: |
              #cloud-config
              users:
                - name: ${PRINCIPAL}
                  sudo: ALL=(ALL) NOPASSWD:ALL
                  shell: /bin/bash
                  lock_passwd: true
              write_files:
                - path: /etc/ssh/talu_ca.pub
                  content: "${CA_PUBKEY}"
                  permissions: "0644"
                - path: /etc/ssh/sshd_config.d/60-talu-ca.conf
                  content: |
                    TrustedUserCAKeys /etc/ssh/talu_ca.pub
                    PasswordAuthentication no
              runcmd:
                - systemctl restart ssh
---
apiVersion: v1
kind: Service
metadata:
  name: ${VM}-ssh
  namespace: ${NS}
  labels:
    talu.io/ssh-expose: "true"
    talu.io/vm: "${VM}"
    talu.io/project-uuid: "${PROJECT_UUID}"
spec:
  selector: { kubevirt.io/vm: ${VM} }
  ports: [{ name: ssh, port: 22, targetPort: 22 }]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: ${VM}-ssh-pin
  namespace: ${NS}
  labels:
    talu.io/vm: "${VM}"
    talu.io/project-uuid: "${PROJECT_UUID}"
spec:
  endpointSelector: { matchLabels: { kubevirt.io/vm: ${VM} } }
  ingress:
    - fromEndpoints:
        - matchLabels: { k8s:io.kubernetes.pod.namespace: ${POM_NS} }
      toPorts: [{ ports: [{ port: "22", protocol: TCP }] }]
YAML
}

pomerium_route() {
cat <<YAML
# Merge into the Pomerium config 'routes:' list (or emit as an Ingress once Pomerium
# runs the Ingress Controller). Selects the VM's Service; OIDC-gated to the tenant.
- from: tcp+https://ssh-${VM}.${LAB_DOMAIN}:22
  to: tcp://${VM}-ssh.${NS}.svc.cluster.local:22
  allowed_users: [${ALLOWED_USERS}]
YAML
}

openbao_role() {
cat <<JSON
{"key_type":"ca","allow_user_certificates":true,"allowed_users":"${PRINCIPAL}","default_user":"${PRINCIPAL}","ttl":"15m","allowed_extensions":"permit-pty","default_extensions":{"permit-pty":""}}
JSON
}

if [ -n "$OUTDIR" ]; then
  mkdir -p "$OUTDIR"
  k8s_bundle       > "$OUTDIR/${VM}-k8s.yaml"
  pomerium_route   > "$OUTDIR/${VM}-pomerium-route.yaml"
  openbao_role     > "$OUTDIR/${VM}-openbao-role.json"
  echo "wrote:" >&2
  echo "  $OUTDIR/${VM}-k8s.yaml            # kubectl apply -f" >&2
  echo "  $OUTDIR/${VM}-pomerium-route.yaml # merge into Pomerium config" >&2
  echo "  $OUTDIR/${VM}-openbao-role.json   # bao write ssh/roles/${VM} - < this" >&2
else
  k8s_bundle
  { echo; echo "# ===== companion artifacts (NOT kubectl-apply — different systems) ====="; \
    echo "# --- Pomerium route (merge into config) ---"; pomerium_route | sed 's/^/#   /'; \
    echo "# --- OpenBao role (bao write ssh/roles/${VM} -) ---"; echo "#   $(openbao_role)"; } >&2
fi
