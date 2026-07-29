# Talu production-readiness & KaaS-finish roadmap

Synthesis of six design studies (tenant DR, secrets, network isolation, upgrades, observability, KaaS
productization) into one prioritized plan. Each section below is a summary; the full designs and
per-workstream file lists are the source of the estimates.

The theme that runs through all six: **Talu already has the primitives** — the reconciler-CronJob idiom
(`route-sync`, Headlamp `cluster-sync`), CAAPH `HelmChartProxy` (auto-installs Cilium into tenants), the
spoof-proof per-tenant ingest gateway (Tier-2 logging), `kube-state-metrics` CustomResourceState, per-uuid
keying, and the Velero+Garage+restore-drill discipline. Most of this roadmap is *composing existing patterns*,
not inventing machinery. Three cross-cutting decisions unlock multiple workstreams at once (below).

---

## Cross-cutting decisions (make these first — they change several workstreams)

1. **Provision each tenant cluster into its own `kaas-<slug>` namespace** (the `talu-cluster` chart already
   supports `.Values.namespace`; set it to `kaas-{{ name }}`). Today all tenants share `kaas-capi`, so
   metering/alerts collapse to one fleet series. Per-tenant namespaces make **G8 metering** key on
   `namespace` like `talu:tenant_*` for free, make **network-isolation** scoping precise, and make every
   existing `kaas-.*` dashboard/alert correctly per-tenant. Cheap, high-leverage — do it early.

2. **Mount the Kamaji-created `<name>-admin-kubeconfig` Secret directly** (key `admin.conf` → mount path
   `value`) in the CSI controller, CCM, and autoscaler Deployments. This is the load-bearing insight from
   the KaaS-productization study: the infra-side wiring doesn't need the kubeconfig *materialized at render
   time*, only *mounted* — the pods sit Pending until Kamaji publishes the Secret, then start. That collapses
   "needs a post-provision imperative step" into pure eventual consistency, letting the **chart render the
   whole infra side**. Foundational for KaaS productization, DR, obs, and autoscaling.

3. **Standardize on SOPS + age** for secrets (the repo already anticipates it — `.gitignore`, the
   `secrets.example.yaml` stubs, and the docs all reference SOPS/age; it was just never wired). Flux
   kustomize-controller decrypts natively; `sops -d` serves the ansible path from the *same* files. This is
   the foundation for a real Git-first deployment and is independent enough to start in parallel.

A fourth recurring pattern to reuse verbatim: the **reconciler CronJob** (`route-sync`/`cluster-sync`:
`*/2`, `concurrencyPolicy: Forbid`, `bitnami/kubectl`, diff-apply, restart-consumer-on-change) is the right
tool for every "per-tenant thing that depends on post-provision `.status`" — it recurs as `probe-sync`
(observability G1), `kaas-route-sync` (KaaS productization), and the etcd-snapshot job (DR).

---

## Workstream A — Tenant-cluster DR

**Gap:** Velero backs up the mgmt cluster + VM tenants, but **KaaS tenant clusters are in no backup story** —
losing a tenant's dedicated `kamaji-etcd` loses that cluster; tenant PVC data is only mountable inside the
tenant, so mgmt-side backup can't reach it.

**Approach:** a tenant's DR artifact = **{ etcd snapshot, in-tenant Velero backup }**, both to Garage,
keyed by `project-uuid`.
- **etcd:** a mgmt-side CronJob (the reconciler idiom) enumerates per-tenant DataStores and runs
  `etcdctl snapshot save` (consistent point-in-time — a hot file-copy of the data dir is not restorable) →
  Garage under `s3://kaas-etcd/<uuid>/…`, verify hash, prune. **RPO 15 min.** *This alone closes the stated
  gap; ship it first.*
- **workloads/PVC data:** Velero **inside each tenant** (its node-agents run on the worker VMs where the
  guest kubelet mounts the kubevirt-csi volumes) via a `velero-<name>` **HelmChartProxy** (same mechanism
  that installs Cilium), keyed on a `talu.io/backup: enabled` label. Requires exposing Garage's S3 endpoint
  to tenant clusters (LB-IPAM Service) + a per-tenant bucket/key.
- **Restore:** two tiers — Path A (in-place etcd restore, RTO ≈ minutes + worker re-provision) and Path B
  (full rebuild from chart + Velero restore, storage/version-portable). Ship both.
- **Homes:** mgmt etcd-snapshot = new `components/tenancy/kaas-backup/` + `phys_kaas_backup` role; in-tenant
  Velero = cluster-chart addition + `values.schema.json`; Garage exposure = `components/platform/backup/`
  change. **Validation:** new KT-30/31 destroy-and-restore-with-sentinel (closes the KT-17 data-integrity
  gap in DR context) + generalize the existing restore-test drill per tenant.

**Effort M · Risk Low-Med** (every primitive already exists & is validated; residual risk = Garage has no
WORM/Object-Lock, and etcd-restore correctness under Kamaji's DataStore abstraction — validate early).

---

## Workstream B — Secrets management (SOPS + age)

**Gap:** no systematic secrets story — IdP client secret + Dex bcrypt are **committed plaintext** in
`group_vars` and hardcoded in `route-sync.yaml`; Pomerium secrets/SSH-CA are minted imperatively
(non-reproducible — a rebuild mints a *new* SSH CA, invalidating guest trust); Garage/pkg-signing keys are
ad-hoc; tenant guest secrets are inlined in HelmReleases (blocks committing a tenant). This blocks GitOps.

**Approach:** complete the already-intended SOPS+age (rejected: Sealed Secrets — poor ciphertext portability
across the frequent lab-rebuild loop & can't serve ansible; ESO+Vault — violates standalone-first as a
*default*; keep ESO as a documented opt-in swap). Encrypted Secret manifests live in `environments/<site>/`
(the customization boundary); Flux `Kustomization` gets `decryption: {provider: sops}`, ansible applies the
*same* files via `sops -d`. Per-env age keys, path-scoped `.sops.yaml` recipients, the `sops-age` Secret the
one irreducible bootstrap. Add an `existingSecret`/`guestSecretRef` seam to `talu-tenant` so tenant cloud-init
secrets are SOPS files (or orchestrator-supplied). **Watch:** `kustomize build | kubectl apply` (the
`dev/lab/sync.sh` fast path) does NOT decrypt — keep encrypted files out of the kustomize resource graph
(so `make kbuild` passes) and add a `sops -d` step or use the Flux path.

**Migration (phased, low-risk):** (0) `.sops.yaml` + keys + `docs/operations/secrets.md`; (1) new
`components/platform/secrets/` mechanism component; (2) **migrate committed plaintext** (IdP/Dex — highest
value); (3) imperative platform secrets → generate-once/encrypt/commit (fixes the SSH-CA rebuild regression);
(4) tenant guest secrets; (5) wire the Flux decryption Kustomization (completes GitOps); (6) optional ESO
overlay. Add a gitleaks CI gate. **Effort M · Risk Low** (no runtime component; risks are bootstrap ordering
& the dev-loop decrypt gap). Rotate the currently-committed demo creds as part of migration.

---

## Workstream C — Multi-tenant network isolation

**Gap (root cause):** egress is never enforced — no CNP selects tenant/worker endpoints for **egress**, so
Cilium leaves egress allow-all. That's why KT-06 (tenant→mgmt API) was stopped only by authn (401), not the
network, and KT-07 leaned on distinct CAs.

**Approach — three layers, deny that can't be re-opened:**
- **Layer A (new `components/platform/network-policy/`):** cluster-wide `CiliumClusterwideNetworkPolicy`
  selecting any `talu.io/project-uuid` endpoint with **`egressDeny` to entities `kube-apiserver`, `host`,
  `remote-node`** (+ mgmt CIDRs except DNS). Cilium deny always beats allow, so this holds even if a tenant
  writes `egress: 0.0.0.0/0`. **This is the KT-06 fix.** Entities are IP-family-agnostic → most of the IPv6
  story for free.
- **Layer B (tenant-chart `netpol-baseline.yaml`):** per-tenant default-deny egress with an allow-list
  (own namespace, cluster DNS, own LB/logging) + the mandatory `fromEntities: [host, remote-node, health]`
  ingress allow (the loki-policy lesson — omit it and endpoints flap NotReady). Cross-tenant isolation
  (KT-07) falls out for free.
- **Layer C:** existing per-VM security groups + `ssh-pin` become additive allow contributors (unchanged
  tenant API).
- **KaaS:** a worker-VM baseline (cluster-chart) allowing DNS + tenant-API LB + **konnectivity-server** +
  peer workers, while Layer A still blocks worker→mgmt-API. Kamaji CP pods must NOT be caught by Layer A.

**Rollout:** stage with `egressDefaultDeny: false`, observe Hubble `*_namespace` drop flows under real
traffic, then flip per environment (CCNP has no audit mode). **Validation:** re-run KT-06′/KT-07′ expecting
network DROP (Hubble drop record) not 401, plus lock-out negative tests (konnectivity stays connected,
LB-IPAM ARP answers, no pod flaps). **Effort M · Risk Med** — concentrated in lock-out of legit control
traffic; mitigations = entities over CIDRs, the host/health allow, precise `endpointSelector`, staged rollout,
Flux-reversible.

---

## Workstream D — Upgrade orchestration

**Gap:** `components/platform/upgrades/` is a skeleton; upgrades are imperative `talosctl`. No compat-matrix
enforcement (KubeVirt v1.8 caps k8s ≤1.35 is a *comment*). A Cilium pin already **drifted** (component 1.18.1
vs phys 1.19.6) — exactly what orchestration must catch.

**Approach — four surfaces + one guardrail:**
- **Talos OS + k8s:** adopt **tuppr** (`TalosUpgrade`/`KubernetesUpgrade` CRs with **CEL health gates**:
  Ceph HEALTH_OK, `osImage==target`, Ready, etcd quorum). The prereq (`kubernetesTalosAPIAccess`) already
  exists in `dev/talos/patch.yaml` — **fix the namespace to match tuppr's**. Crux: ensure tuppr's per-node
  drain triggers **KubeVirt live-migration** (reproduce the `kubevirt.io/drain` taint semantics of
  `node-maintenance.sh`, kept as the drain impl / escape hatch); refuse if any VMI is non-migratable.
- **Platform components:** Flux + **Renovate** (`allowedVersions` = matrix constraints) proposes bumps;
  encode the Cilium-no-`--reuse-values` gotcha in the runbook.
- **KaaS tenants:** CAPI-native — bumping the chart's `kubernetesVersion` rolls the KamajiControlPlane pods
  then rolling-replaces MachineDeployment workers on the new containerdisk; tenant k8s ≤ min(mgmt, newest
  capk image). A values-file PR, no new machinery.
- **KaaS providers:** `clusterctl upgrade apply` (an ansible-role/runbook concern).
- **Compat matrix (`compat-matrix.yaml` ConfigMap)** enforced 3 ways: **Kyverno ClusterPolicy** (cross-resource
  `apiCall` reads the live KubeVirt version, rejects any `KubernetesUpgrade`/HelmRelease that would put
  k8s>1.35 while KubeVirt v1.8 — makes the comment a machine-enforced invariant), Renovate constraints, and
  a CI check. Kyverno *enforces*, never generates (lab-notes #40).

**Homes:** component `upgrades/` (tuppr + CRs + matrix), Kyverno policy, new `phys_upgrades` role +
imperative fallback, `docs/operations/upgrades.md`, CI matrix check. **Validation:** extend the validated
node-reboot/drain drills (KT-25, MHC) into a real A/B upgrade on the phys lab. **Effort M · Risk Med-High** —
the tuppr-drain-triggers-live-migration integration is the risk; keep the scripts as fallback.

---

## Workstream E — Observability finish

**Gap:** replica-count alerts are blind to the outages that matter (KT-24 datastore quorum-loss, KT-19 LB
failover — CP pods stay Ready while the API is dead); no KaaS metering; tenant clusters run blind internally.

**Approach (prioritized):**
- **G1 blackbox tenant-API probe (highest value):** deploy blackbox-exporter (Prometheus is already
  Probe-ready) + a **`probe-sync` reconciler** (clone `route-sync`) that reads each `tcp
  .status.controlPlaneEndpoint` and materializes one multi-target `Probe` (targets can't be templated from
  PromQL, so a reconciler must materialize them) → `KaasTenantApiserverDown` alert + availability panel.
  Validated by re-running KT-19/KT-24.
- **G8 metering:** `talu:kaas_*` recording rules (CP CPU/RAM, worker count, tenant PVC bytes) — **keyed on
  tenant, which requires the per-tenant `kaas-<slug>` namespace** (cross-cutting decision #1) or a fragile
  `label_replace` on pod names. Lead with the namespace change.
- **G6 completion (cheap, do early — unblocks KT-20):** alerts on the KSM series `ksm-crs.yaml` already
  produces (`KaasMachineDeploymentStalled`, `KaasClusterNotReady`) + extend CRS to Machine/MachineSet phases.
- **Tenant-cluster internal obs:** in-tenant Grafana Alloy via **HelmChartProxy** → a **per-tenant
  hard-stamping gateway** in the mgmt cluster (the exact spoof-proof Tier-2 logging pattern — never trust the
  tenant cluster's labels) → central Loki + a Prometheus remote-write receiver, with Cilium making the
  gateway the only path. Stage logs-first (reuses the existing gateway almost verbatim), metrics second.
- **The rest:** G2 konnectivity health (verify the metrics port first), G5 CDI stuck-import, G3 LB-IPAM
  lease/empty-ingress, G4 tenant-PVC-pending, G7 per-tenant-RED (a documented decision).

**Discipline:** every rule must pass `count(series) > 0` before commit (the repo's no-dead-rules rule);
graded by KT-30/31/32. **Effort:** G1/G6/G8/G3/G4/G5 are S-M each; tenant-cluster obs is L (Med-High risk —
remote-write cardinality on shared Prometheus + Cilium egress footguns).

---

## Workstream F — KaaS productization & finish

**Gap:** the KaaS layer is validated but lives mostly as the `phys_kaas_tenant` role; only the declarative
half is a chart. Plus: no worker autoscaling; the console uses tenant *admin* creds; no per-user OIDC RBAC.

**F1 — Graduate the wiring (no imperative post-steps).** Using cross-cutting decision #2 (mount the Kamaji
Secret directly), render the **whole infra side in the chart**: dedicated `kamaji-etcd` (subchart), CSI
controller + CCM (mounting `<name>-admin-kubeconfig` directly), a **`ClusterResourceSet`** for the in-tenant
manifests (CSI node plugin, `CSIDriver`, StorageClass, Pomerium impersonation SA/RBAC — CRS uses the
CAPI-held kubeconfig, needs `EXP_CLUSTER_RESOURCE_SET`), and a **`kaas-route-sync` CronJob** for the one
un-chartable edit (the shared Pomerium config blob). Move the cluster-wide `ceph-block` StorageProfile patch
to the storage/CDI component. Result: a tenant cluster = a `HelmRelease` + a values file, like `talu-tenant`;
retire `phys_kaas_tenant`. **Rejected: a custom operator** — premature (the credential dependency isn't hard
once you mount Secrets) and off-philosophy; revisit only if credential rotation / strict delete-ordering
becomes real. **Effort M · Risk Med** (CRS apply-ordering into a not-yet-CNI'd tenant — CRS retries; the
direct-mount `items` remap).

**F2 — Worker autoscaling.** One `cluster-autoscaler --cloud-provider=clusterapi` per tenant (chart-gated on
`workers.autoscaling.enabled`), rendering the CAPI min/max annotations. **Load-bearing gotcha:** when
autoscaling, the chart must **omit `spec.replicas`** (else Flux/helm reverts every scale event) + a
`driftDetection.ignore` on `/spec/replicas`. KubeVirt specifics: capacity annotations for scale-from-zero,
`--max-node-provision-time ≥ MHC nodeStartupTimeout (15m)`. **Effort M · Risk Med.**

**F3 — Access RBAC.** (a) **Read-only console** — re-align to the *original* `phys_headlamp` intent: the CRS
mints a per-tenant read-only SA (`view`), `cluster-sync` builds Headlamp contexts from that SA token instead
of admin client-certs, with an `admin` toggle gated to an ops allow-list (default read-only = least
privilege). (b) **Per-user OIDC RBAC** — opt-in chart value setting OIDC apiserver args on the *tenant's*
`KamajiControlPlane`. **Key insight:** this is viable where mgmt-apiserver OIDC was a fragile hairpin, because
the **tenant apiserver runs as pods** (normal pod DNS, can reach `dex.identity.svc` directly — no host-DNS
hairpin). Needs Dex to emit groups for group-RBAC. Keep Pomerium-impersonation as the zero-config default.
**Effort:** F3a Low, F3b Med (issuer/CA reachability is the crux; CRD CEL restricts mutating OIDC args on a
live TCP — set at create).

---

## Recommended sequence

**Tier 0 — cheap, high-leverage, unblock others (days):**
- Cross-cutting decisions: per-tenant `kaas-<slug>` namespace; adopt the mount-Kamaji-Secret pattern; start SOPS scaffolding.
- G6-completion alerts (unblocks KT-20). Fix the Cilium pin drift + author the compat-matrix. Clean the stale Pomerium routes (`k8s-tenant-b`, `fedora`, `ubuntu`).

**Tier 1 — highest-value production gaps (the "make it credible" set):**
- **G1 blackbox tenant-API probe** (E). **etcd-snapshot DR** (A) — closes "lose kamaji-etcd = lose cluster".
- **Network isolation Layer A** (C) — the `egressDeny` KT-06 fix. **SOPS phase 2** (B) — kill committed plaintext.

**Tier 2 — structural:**
- **KaaS chart graduation** (F1) — the big one; DR-in-tenant-Velero, obs-in-tenant-agent, and autoscaling all ride on it.
- SOPS phases 3-5 + Flux decryption Kustomization (B). Network isolation Layers B/C + KaaS worker baseline (C).
- Upgrade orchestration: tuppr + Kyverno compat gate (D). In-tenant Velero DR (A).

**Tier 3 — finish:**
- Worker autoscaling (F2). Tenant-cluster internal observability (E). G8 metering + remaining G2-G5 (E).
- Read-only Headlamp + opt-in per-user OIDC RBAC (F3). Optional ESO overlay (B).

**Dependencies:** F1 (chart graduation) is the hub — A's in-tenant Velero, E's in-tenant agent, and F2
autoscaling are cleanest once the chart is the vehicle and the CRS/mount pattern exists. B (SOPS) and D
(upgrades) are largely independent and can run in parallel. The `kaas-<slug>` namespace decision should land
before G8 and the isolation baselines.

## Effort at a glance

| Workstream | Effort | Risk | First increment (highest value / lowest risk) |
|---|---|---|---|
| A — Tenant DR | M | Low-Med | etcd-snapshot CronJob + freshness alert (closes the stated gap alone) |
| B — Secrets (SOPS) | M | Low | migrate the committed IdP/Dex plaintext |
| C — Network isolation | M | Med | Layer A `egressDeny` to `kube-apiserver` (KT-06 fix) |
| D — Upgrades | M | Med-High | compat-matrix + Kyverno gate + Cilium-drift fix |
| E — Observability | S-M (L for tenant-cluster obs) | Low (Med-High tenant obs) | G1 blackbox probe; G6 alerts |
| F — KaaS finish | M each part | Med | F1 chart graduation (unlocks A/E/F2) |

Full per-workstream designs, rationale, alternatives-rejected, and file lists are in the six planning
studies these summaries were distilled from.
