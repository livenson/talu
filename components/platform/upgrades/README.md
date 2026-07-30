# upgrades

**Responsibility:** version-compatibility guardrails + (planned) tuppr-driven Talos/Kubernetes rollouts.

The runbook — the four version surfaces, the drain-must-live-migrate crux, the Cilium `--reuse-values`
gotcha — is [`docs/operations/upgrades.md`](../../../docs/operations/upgrades.md).

## What's in here

- **`compat-matrix.yaml`** — the single source of truth for which component versions may run together.
  The binding constraint is **KubeVirt v1.8 → Kubernetes ≤ 1.35**. Carries both a human-readable
  `matrix.yaml` and **flat keys** (`kubernetes.max`, `kubernetes.allowedRange`, `cilium.current`, …)
  for machine consumers. Enforced three ways from this one file:
  - **CI:** `ci/check-compat-matrix.py` (`make compat-check`) — fails on any pin drift / over-ceiling.
  - **Kyverno:** the `talu-kaas-upgrade-compat` ClusterPolicy (in `components/platform/kyverno/`) reads
    the live KubeVirt version + this matrix and denies an over-ceiling `KubernetesUpgrade` (Audit-first).
  - **Renovate:** `allowedVersions` constraints keep bump PRs inside the windows.

## Planned (tuppr)

tuppr `TalosUpgrade`/`KubernetesUpgrade` CRs with **CEL health gates** (Ceph HEALTH_OK, `osImage ==
target`, Ready, etcd quorum) land here. The Talos-API prereq (`kubernetesTalosAPIAccess`) is already
granted in `dev/talos/patch.yaml` (namespace `tuppr-system`). The crux is that tuppr's node drain must
trigger KubeVirt **live-migration** (the `kubevirt.io/drain` taint), refusing when a VMI is
non-migratable — see the runbook. Until adopted, substrate upgrades use `make talos-upgrade`.

This is a reusable base — part of `components/` (the product). Adopters do **not** edit it; version
pins per site live in `environments/<site>/`.
