# Upgrades

How Talu moves its four version surfaces forward without breaking the compat matrix or evicting VMs
ungracefully. Component: [`components/platform/upgrades/`](../../components/platform/upgrades/).

## The binding constraint (read first)

**KubeVirt v1.8 targets Kubernetes ≤ 1.35.** Jumping the substrate to 1.36 breaks `virt-launcher`. This
is not advice — it is enforced three ways from one source of truth,
[`compat-matrix.yaml`](../../components/platform/upgrades/compat-matrix.yaml):

| Enforcer | When | What |
|---|---|---|
| **CI** (`ci/check-compat-matrix.py`, `make compat-check`) | every PR | fails if any Cilium/k8s pin in the repo drifts from the matrix or exceeds the ceiling. Caught the real Cilium 1.18.1↔1.19.6 drift. |
| **Kyverno** (`kaas-upgrade-compat` ClusterPolicy) | admission | reads the live KubeVirt version + the matrix; denies a `KubernetesUpgrade` past the ceiling. Audit-first — flip to Enforce per-env once verified. |
| **Renovate** (`allowedVersions`) | bump PRs | keeps automated version bumps inside the matrix windows. |

**Editing the matrix and lab-notes together is mandatory** — they must never disagree.

## The four surfaces

### 1. Talos OS + Kubernetes (the substrate) — tuppr

Adopt **tuppr** (`TalosUpgrade` / `KubernetesUpgrade` CRs) with **CEL health gates** so a rollout stops
if the cluster is unhealthy rather than marching through it. Gates to encode: Ceph `HEALTH_OK`, node
`osImage == target`, all nodes `Ready`, etcd quorum intact.

- **Prerequisite (already granted):** `machine.features.kubernetesTalosAPIAccess` in the Talos config
  (`dev/talos/patch.yaml`) lets the controller drive `talosctl` from a pod. The allowed namespace must
  match the controller's (`tuppr-system` for tuppr) — both it and `system-upgrade` are listed.
- **THE CRUX — drain must live-migrate VMs, not kill them.** tuppr drains each node before upgrading
  it. That drain MUST trigger KubeVirt's evacuation (live-migration) the same way `make node-drain`
  does — via the `kubevirt.io/drain` taint and `evictionStrategy: LiveMigrate` (set by the kubevirt
  role). Confirm tuppr's drain reproduces that taint semantics, and **refuse the upgrade if any VMI is
  non-migratable** (ephemeral-containerDisk KaaS workers are not migratable — drain them via CAPI
  machine-replace, or accept their recreation). `dev/lab/node-maintenance.sh` stays the manual drain /
  escape hatch. See [`node-maintenance.md`](node-maintenance.md).
- Roll **one control-plane node at a time**; wait for the CEL gate between nodes.

### 2. Platform components (Flux + Renovate)

Renovate proposes bumps inside the matrix; Flux applies them. **Cilium gotcha (lab-notes #24):** never
`helm upgrade --reuse-values` across a Cilium minor bump — it drops the chart's new default subtrees
(`standaloneDnsProxy.enabled: nil pointer`). The Flux `HelmRelease` `valuesFrom` path renders values
fresh, so it's safe there; the hazard is only manual `helm` upgrades.

### 3. KaaS tenant clusters (CAPI-native)

Bump the tenant's `talu-cluster` values `kubernetesVersion`: CAPI rolls the `KamajiControlPlane` pods,
then rolling-replaces `MachineDeployment` workers on the new containerdisk. **Tenant k8s ≤ min(mgmt,
newest `quay.io/capk` image)** — there's no v1.35 capk image yet, so tenants track v1.34.x. A values-file
PR, no new machinery. The MHC + the kubelet-config strip (in the chart) cover the join.

### 4. KaaS providers (clusterctl)

`clusterctl upgrade plan` → `clusterctl upgrade apply` for CAPI/Kamaji/CAPK/CAAPH. An ops action, not
GitOps — record the before/after provider versions in the compat matrix.

## Runbook: raising the substrate a minor version

1. `make compat-check` locally — confirm the target is within the ceiling. If it's a k8s bump toward the
   cap, verify **KubeVirt** supports it first and raise `compat-matrix.yaml` (+ lab-notes) in the same PR.
2. Snapshot etcd (`talosctl etcd snapshot`) and confirm the Velero + KaaS-etcd DR jobs are green.
3. Apply the `TalosUpgrade` (or `KubernetesUpgrade`) CR; watch the CEL gate and that each node's VMs
   live-migrate (Hubble/`virtctl`), not restart.
4. After: nodes `Ready`, Ceph `HEALTH_OK`, `kubectl get tcp -A` all Ready, `KaasTenantApiserverDown`
   not firing.

## Status

The compat-matrix + CI check + Kyverno gate (Audit) are **live**. tuppr adoption (controller install +
the CEL-gated CRs + the drain-live-migration validation) is the **open implementation** — a real A/B
upgrade on the phys lab is the graduation test (extend the KT-25 node-reboot/MHC drills). Until then,
substrate upgrades use the imperative `make talos-upgrade` path ([`node-maintenance.md`](node-maintenance.md)).
