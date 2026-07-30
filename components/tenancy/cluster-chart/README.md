# talu-cluster chart

The **managed tenant-Kubernetes API** — a tenant cluster is a values file, exactly as a VM tenant is
a [`talu-tenant`](../tenant-chart/) values file. Its `values.schema.json` **is** the API; every
rendered object carries `talu.io/project-uuid`. See the architecture doc:
[`docs/architecture/kaas.md`](../../../docs/architecture/kaas.md).

## What it renders (the declarative half)

`templates/cluster.yaml` renders the Cluster API objects for one hosted-control-plane cluster
(Kamaji control plane + KubeVirt workers):

| Object | Purpose |
|---|---|
| `Namespace` (PSA privileged) | infra home for the CAPI objects + worker VMs |
| `Cluster` + `KubevirtCluster` | the CAPI cluster (KubevirtCluster annotated `managed-by: kamaji`) |
| `KamajiControlPlane` | hosted apiserver/CM/scheduler + konnectivity pods; points at the tenant's DataStore |
| `KubevirtMachineTemplate` + `KubeadmConfigTemplate` + `MachineDeployment` | worker VMs + their bootstrap |
| `MachineHealthCheck` | auto machine-replace when a worker node stays NotReady (crash recovery) |
| `HelmChartProxy` | auto-installs Cilium into the tenant on the `cni: cilium` label |

Minimal values:

```yaml
name: tenant-a
projectUuid: "…"           # the manager join key
debugPublicKey: "ssh-ed25519 …"   # operator break-glass into node guests
# everything else defaults (v1.34.1, 2 CP replicas, 2 workers, dedicated etcd on local-path)
```

## The cross-cluster wiring (`wiring.enabled`)

A tenant cluster needs wiring that depends on the tenant's kubeconfig — which only exists after the
control plane is up. The **graduation insight** (F1 in
[`docs/development/production-readiness-plan.md`](../../../docs/development/production-readiness-plan.md)):
that wiring doesn't need the kubeconfig *at render time*, only *mounted* — so the chart can render it
all, and the pods sit Pending until Kamaji publishes the `<name>-admin-kubeconfig` Secret, then start.
No imperative post-provision step. Set `wiring.enabled: true`:

| Rendered (when `wiring.enabled`) | Where | How it gets the kubeconfig |
|---|---|---|
| `kubevirt-csi` controller + infra RBAC + `driver-config` | infra (tenant ns) | **direct mount** of `<name>-admin-kubeconfig` (key `admin.conf` → `value`) |
| `cloud-provider-kubevirt` (CCM) + RBAC + cloud-config | infra (tenant ns) | same direct mount |
| in-tenant CSI node plugin / `CSIDriver` / StorageClass + Pomerium impersonation RBAC + admin binding | tenant | `ClusterResourceSet` (CAPI applies with its held kubeconfig) |

Cluster-scoped objects are per-tenant-named, and the tenant lands in a dedicated `kaas-<name>`
namespace (set `namespace` to override) so multiple tenants don't collide. `ClusterResourceSet`
requires `EXP_CLUSTER_RESOURCE_SET=true` on the management cluster.

Still prerequisites (not yet chart-rendered): the **dedicated etcd + DataStore** (`kamaji-etcd` helm
release named `<name>-local`) and the **shared Pomerium route** (env-specific config blob; the
`kaas-route-sync` CronJob is the planned mechanism). Tenant-cluster DR (in-tenant Velero) and worker
autoscaling attach here next.

> **Validation status:** `wiring.enabled` renders clean (`helm template`/`kubeconform`, wiring on and
> off, in CI) but the *graduated chart path* is **not yet lab-exercised** — the validated path remains
> the [`phys_kaas_tenant`](../../../ansible/roles/phys_kaas_tenant/) ansible role. Treat the chart
> wiring as built-but-not-yet-run until a lab round-trip confirms it, then retire the role.

## Prerequisites (management cluster)

`clusterctl init --bootstrap kubeadm --control-plane kamaji --infrastructure kubevirt --addon helm`
(validated: CAPI v1.13.4 / Kamaji CP v0.20.0 / CAPK v0.11.2 / CAAPH v0.6.4), plus local-path (for
per-tenant etcd), Rook-Ceph RBD, and Cilium with `socketLB.hostNamespaceOnly`.

## Status

The rendered **declarative** manifests are validated end-to-end on the physical lab (two tenant
clusters, full resilience suite — see
[`docs/development/kaas-test-results.md`](../../../docs/development/kaas-test-results.md)). The
**wiring** (`wiring.enabled`) is a faithful chart-rendering of the validated `phys_kaas_tenant` role,
CI-linted on and off, but not yet lab-exercised as a chart (see the validation-status note above). This
is a reusable base — adopters set values in `environments/<site>/`, not here. The annotated source of
truth is `ansible/roles/phys_kamaji/files/capi-tenant-reference.yaml`.
