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

## The other half (post-provision wiring)

A tenant cluster needs cross-cluster wiring that **cannot** be rendered up front, because it depends
on the tenant's kubeconfig/CA, which only exist after the control plane is up:

1. **Dedicated etcd + DataStore** — a `kamaji-etcd` helm release on `local-path` named `<name>-local`
   (the chart's default `dataStore`). Deploy this **before** the cluster reconciles.
2. **kubevirt-csi** — infra-side controller (with the tenant kubeconfig) + tenant node plugin +
   StorageClass → `ceph-block`.
3. **cloud-provider-kubevirt** — LB controller for tenant `type: LoadBalancer` Services.
4. **Pomerium kubectl route** — impersonation SA in the tenant + a route with the tenant CA + SA token.

Today that wiring is the **`phys_kaas_tenant` ansible role**
([`ansible/roles/phys_kaas_tenant/`](../../../ansible/roles/phys_kaas_tenant/)), validated end-to-end
on the physical lab. Graduating it into a small operator (or Flux post-build hook) is the next step;
this chart is the declarative half it builds on.

## Prerequisites (management cluster)

`clusterctl init --bootstrap kubeadm --control-plane kamaji --infrastructure kubevirt --addon helm`
(validated: CAPI v1.13.4 / Kamaji CP v0.20.0 / CAPK v0.11.2 / CAAPH v0.6.4), plus local-path (for
per-tenant etcd), Rook-Ceph RBD, and Cilium with `socketLB.hostNamespaceOnly`.

## Status

The rendered manifests are **validated end-to-end** on the physical lab (two tenant clusters, full
resilience suite — see [`docs/development/kaas-test-results.md`](../../../docs/development/kaas-test-results.md)).
The chart form is validated by `helm template`/`helm lint`; deploying it **via Flux** (rather than the
ansible role) is not yet wired. This is a reusable base — adopters set values in
`environments/<site>/`, not here. The annotated source of truth is
`ansible/roles/phys_kamaji/files/capi-tenant-reference.yaml`.
