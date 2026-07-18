# Rocky9 validation plan (no-KVM quick-mode)

How Talu is implemented and validated end-to-end on a single remote Rocky 9 cloud VM with
**no hardware virtualization**. This is the plan's documented *quick-mode / no-KVM fallback*
instantiated as the `rocky9-sandbox` overlay — a **throwaway, rebuildable** environment that
proves **correctness**, and doubles as the project's "try it on one VM" quickstart and CI
e2e gate.

## What this environment proves — and what it can't

**Validated:** GitOps reconcile, every CRD/subresource surface, the identity + secrets + SSH
+ access plane (incl. the security acceptance test), genuine storage semantics
(snapshots/clones on Ceph), the tenant API, and the full §10 integration contract.

**Not validated here** (deferred to KVM-capable `dev-shared`/`pilot` hardware): performance
and latency numbers, representative live migration, the real Talos A/B upgrade, and the
KubeVirt-bump migration-compatibility gate. Moving to that hardware is a **values change**
(a different overlay), not a rebuild.

## Why the VM constrains us

| Fact about the lab VM | Consequence |
|---|---|
| No `/dev/kvm`, no vmx/svm | No Talos QEMU provisioner → **Talos-in-Docker**; KubeVirt runs `useEmulation: true` (TCG) |
| Single 100 GB disk, no spare block device | Rook Ceph OSDs on **loop devices** (`dev/loopdev`) — real block semantics, not real spindles |
| OpenStack hosting Docker rule | `/etc/docker/daemon.json` (bridge `192.168.67.1/24`, **MTU 1400**, overlay2) **before first start**, or network lockout → whole CNI stack pinned under MTU 1400 |
| Behind NAT / floating IP, single NIC | Reach services via the **SSH tunnel** (`make lab-tunnel`), not routable LB IPs |
| `ulimit -n` 1024, modules not loaded | Raised via `bootstrap/rocky9/bootstrap.sh` |

## Working loop

You edit on your laptop and drive the remote lab:

```sh
make lab-push     # Stage 0: rsync repo + run host bootstrap on the lab
make up           # create the Talos-in-Docker cluster on the lab
make lab-tunnel   # open the persistent SSH tunnel + fetch kubeconfig
make lab-sync     # kustomize build environments/rocky9-sandbox | kubectl apply --server-side
make lab-status   # read reconcile/health back, rendered locally
```

`make try` chains push → up → tunnel → sync. Every stage below is driven this way.

## Stages (each has an explicit exit criterion)

De-risk the three VM-specific unknowns as cheap spikes first, then build the overlay
top-to-bottom, culminating in the security acceptance test and the integration-contract
proof.

### Stage 0 — Host bootstrap · `bootstrap/rocky9/bootstrap.sh` (`make lab-push`)
Docker with the mandated `daemon.json` **before first start** (lockout checkpoint: the script
pauses for you to confirm SSH from a second session), kernel modules
(`overlay br_netfilter rbd nbd loop`), raised inotify/file limits, tooling
(`talosctl kubectl helm flux virtctl cosign`), SELinux left enforcing.
**Exit:** second SSH session confirms networking survived; `docker run hello-world` OK.

### Stage 1 — Spike A: Talos-in-Docker + Cilium under MTU 1400 (`make up` + `lab-sync`)
Single node (CP+worker), IPAM mode **pinned** (immutable later), Cilium with MTU ≤1350 and
Hubble.
**Exit:** node Ready; Hubble flows; a **large-payload pod-to-pod test passes** (proves MTU —
the subtle host failure mode). Fix here before anything else.

### Stage 2 — Spike B: Rook Ceph on loop devices (`dev/loopdev/setup.sh`)
2 OSD / 1 MON / 1 MGR, pool `size 2 / failureDomain osd`, `ceph-block` (RWX-capable) +
VolumeSnapshotClass.
**Exit:** `HEALTH_OK`; PVC provisions; **CSI snapshot + clone completes**; down one OSD → I/O
continues on the surviving replica.

### Stage 3 — Spike C: KubeVirt/CDI under emulation
`useEmulation: true`, migration/hotplug gates on (inert but API-final); CDI scratch=local-path,
default=ceph-block, DataImportCron source=VolumeSnapshot.
**Exit:** a cloned VM boots under TCG; `virtctl console` works; disk grows online; VM survives
node restart. *Recorded n/a:* boot/migration timing; hotplug resize = reboot (single node);
persistent-EFI VMs need RWX.

### Stage 4 — Core services + tier-1 stable-IP proof
cert-manager internal CA; local-path as CDI-scratch only; zot with TLS. Tier-1 test:
per-tenant `CiliumLoadBalancerIPPool` (internal range) + `lbipam.cilium.io/ips` on a VM
Service — chosen address assigned, wrong-pool refused, address independent of the pod.
**Exit:** Flux reconciles empty→green with zero manual applies; a LoadBalancer Service answers
**through the tunnel**; the chosen internal IP is validated.

### Stage 5 — Image pipeline shape
`images/ubuntu-lts/Containerfile` (bake capabilities, inject identity); local
`virt-sparsify`+`cosign`+push-to-zot; DataImportCron imports on digest change and rolls the
`ubuntu-lts` DataSource.
**Exit:** a freshly pushed image goes cluster-live via the cron; a tenant clone comes off the
rolled snapshot; the **ephemeral (containerDisk, no PVC)** flavor boots.

### Stage 6 — Identity, secrets & SSH chain + **security acceptance test** (the payoff)
Keycloak (behind the IdP-swap interface), OpenBao (1-member Raft, manual-unseal runbook,
audit on, SSH CA), Pomerium (OIDC, per-route policy incl. `allow: public`), Cilium pinning.
Exercise the **wrapped-token bootstrap** (mint `role/vm-<name>` → response-wrap single-use
SecretID → cloud-init → `bao-agent` unwraps; pre-unwrapped token fails loudly) and the **SSH
chain** (OIDC `bao login` → `ssh/sign/member` cert → `pomerium-cli tcp` tunnel → cert auth).
**Exit:** unauthenticated route → Keycloak; correct-group user passes; group removal blocks
within session TTL; SSH works **only** via short-lived cert through the tunnel; cross-namespace
reach to a VM port denied, through-Pomerium allowed; Hubble shows the denied attempts.

### Stage 7 — Talu-native tenancy + **§10 integration-contract proof** (Waldur-free)
Prometheus + recording rules for the billing PromQL set; tuppr CRs for API-surface + CEL-gate
validation only (real A/B upgrade deferred). The tenant chart is the tenant API: a tenant/VM
is a values-PR under `environments/rocky9-sandbox/tenants/`, every object carrying
`talu.io/project-uuid`; Headlamp + KubeVirt plugin behind a Pomerium admin route; kubelogin
OIDC + group-scoped RBAC.
**Integration proof (the Waldur-independence test):** with **no manager present**, exercise all
four §10 verbs — write a labelled tenant+VM, watch DataVolume/VMI status to readiness, read
usage from the Prometheus HTTP API, open a console via the virt-api subresource under the
per-tenant SA.
**Exit:** a tenant values-PR reconciles to a working namespace+VM; Headlamp shows only that
namespace under a scoped login; the four-verb flow works standalone.

## Teardown

`make down` destroys the cluster and detaches loop devices, leaving Docker + `daemon.json` in
place (removing them risks the lockout path). `make lab-down` closes the tunnel.
