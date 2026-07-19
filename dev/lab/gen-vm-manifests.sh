#!/usr/bin/env bash
# Generate the manifest bundle for one SSH-accessible Talu VM — PURE OUTPUT, no cluster mutation.
#
# Intended to be driven by an external orchestrator: Talu's stable surface is
# "write labelled Kubernetes objects" (integration contract §10). Every object carries
# talu.io/project-uuid — the join key an orchestrator reconciles on.
#
# Access model: Pomerium Native SSH. The VM trusts Pomerium's SSH **User CA** (public key,
# baked via cloud-init); users run `ssh <principal>@<vm>@ssh.<domain> -p <port>` and Pomerium
# issues the cert after OIDC. Guest secrets ride in via cloud-init sourced from a Secret
# (cloudInitNoCloud.secretRef) — no OpenBao, no guest agent.
#
# Two artifact kinds:
#   - K8s objects (Namespace, cloud-init Secret, VirtualMachine, Service, CiliumNetworkPolicy)
#     -> kubectl apply
#   - Pomerium ssh:// route fragment  -> merge into the Pomerium config (or the tenant-chart emits it)
#
# Usage:
#   gen-vm-manifests.sh <vm> <namespace> [principal] > bundle.yaml    # K8s to stdout, route to stderr
#   gen-vm-manifests.sh <vm> <namespace> [principal] -o outdir/       # both as files
#
# Inputs (env; flags/positional override):
#   PROJECT_UUID  talu.io/project-uuid       (default: all-zero placeholder — the orchestrator sets the real one)
#   VM_IMAGE      containerDisk image        (default: quay.io/containerdisks/ubuntu:24.04 — OpenSSH)
#   VM_MEMORY     guest memory              (default: 1536Mi)
#   LAB_DOMAIN    external domain            (default: 203-0-113-10.sslip.io)
#   ALLOWED_USERS Pomerium route allow-list  (default: alice@talu.local)
#   CA_PUBKEY     Pomerium User CA public key (default: read from cm pomerium/pomerium-user-ca)
#   GUEST_SECRET  optional content written to /etc/talu/app.env inside the guest (demo of secret injection)
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
ALLOWED_USERS=${ALLOWED_USERS:-alice@talu.local}

# The VM trusts the Pomerium User CA (public key). Non-sensitive; published as a ConfigMap.
if [ -z "${CA_PUBKEY:-}" ] && command -v kubectl >/dev/null 2>&1; then
  CA_PUBKEY=$(kubectl -n pomerium get configmap pomerium-user-ca -o jsonpath='{.data.user_ca\.pub}' 2>/dev/null || true)
fi
[ -n "${CA_PUBKEY:-}" ] || { echo "ERROR: set CA_PUBKEY (Pomerium User CA public key, cm pomerium/pomerium-user-ca)" >&2; exit 1; }

# Optional guest-secret write_files block (arbitrary secret delivered into the guest).
GUEST_BLOCK=""
if [ -n "${GUEST_SECRET:-}" ]; then
  GUEST_BLOCK=$(printf '                - path: /etc/talu/app.env\n                  permissions: "0600"\n                  content: |\n                    %s' "$GUEST_SECRET")
fi

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
# Cloud-init lives in a Secret (keeps any guest secrets out of the VM manifest; the orchestrator writes it).
apiVersion: v1
kind: Secret
metadata:
  name: ${VM}-userdata
  namespace: ${NS}
  labels:
    talu.io/vm: "${VM}"
    talu.io/project-uuid: "${PROJECT_UUID}"
type: Opaque
stringData:
  userdata: |
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
${GUEST_BLOCK}
    runcmd:
      - systemctl restart ssh
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
            secretRef: { name: ${VM}-userdata }
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
  annotations:
    talu.io/allowed-users: "${ALLOWED_USERS}"   # per-tenant SSH-route allow-list (read by the route renderer)
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
        - matchLabels: { k8s:io.kubernetes.pod.namespace: pomerium }
      toPorts: [{ ports: [{ port: "22", protocol: TCP }] }]
YAML
}

pomerium_route() {
cat <<YAML
# Merge into the Pomerium config 'routes:' list (the tenant-chart / expose-vm.sh emits this).
# The route NAME (ssh://${VM}) is the middle token users type: ssh <principal>@${VM}@ssh.${LAB_DOMAIN}
- from: ssh://${VM}
  to: ssh://${VM}-ssh.${NS}.svc.cluster.local:22
  policy:
    - allow:
        and:
          - email:
              in: [${ALLOWED_USERS}]
YAML
}

if [ -n "$OUTDIR" ]; then
  mkdir -p "$OUTDIR"
  k8s_bundle     > "$OUTDIR/${VM}-k8s.yaml"
  pomerium_route > "$OUTDIR/${VM}-pomerium-route.yaml"
  echo "wrote:" >&2
  echo "  $OUTDIR/${VM}-k8s.yaml            # kubectl apply -f" >&2
  echo "  $OUTDIR/${VM}-pomerium-route.yaml # merge into Pomerium config" >&2
else
  k8s_bundle
  { echo; echo "# ===== companion (NOT kubectl-apply — Pomerium config) ====="; \
    echo "# --- Pomerium ssh:// route ---"; pomerium_route | sed 's/^/#   /'; } >&2
fi
