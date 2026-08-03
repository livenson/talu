# Integration reference (detailed)

The [`README.md`](README.md) is the integrator's one-page summary of the **four-verb contract** (write
labelled objects · watch `.status` · read Prometheus · delegate identity). This page is the detailed
reference for each concern an external allocator (e.g. **Waldur**), a self-service portal, or a CI
pipeline touches. Runtime sequence diagrams: [`../architecture/flows.md`](../architecture/flows.md).

Everything below is **declarative and orchestrator-optional** — Talu never calls back to the consumer,
and it runs with no orchestrator at all. **`talu.io/project-uuid` on every object is the join key;
names are handles.**

## §1 · Human login — OIDC

Talu delegates all human authentication to a shared **generic OIDC IdP** (Dex / Keycloak / ZITADEL —
Talu ships Dex by default). The consumer:

- creates/maps a **per-project group** in the IdP (or its upstream), and
- expresses authorization as **group membership** (§4). Talu consumes the OIDC `groups` claim; it never
  calls the orchestrator to check access.

Pomerium (the only ingress) is the OIDC relying party for every HTTP/SSH/kubectl route, so a single
sign-in covers VMs, consoles, dashboards, and managed-cluster `kubectl`.

## §2 · Guest secrets — cloud-init

Per-VM guest configuration (users, SSH keys, files, packages) rides in as **cloud-init from a
Kubernetes `Secret`**, referenced by the VM's `cloudInitNoCloud.secretRef`. The `talu-tenant` chart
renders this Secret from the tenant values; a consumer that writes the lower-level objects supplies its
own Secret and points the VM at it. Secrets never transit Talu's control path in the clear — encrypt at
rest with SOPS/age ([`../operations/secrets.md`](../operations/secrets.md)).

## §3 · Shell access — Pomerium Native SSH

There is **no public `:22` and no static password**. Pomerium is the **SSH proxy and User CA**: an
authenticated user gets a short-lived, principal-scoped certificate and connects
`ssh <principal>@<vm>@ssh.<domain> -p 2222`. A VM opts in by labelling its `Service`
`talu.io/ssh-expose` and annotating `talu.io/allowed-users`; the Pomerium config renderer turns that
into a per-VM route scoped to the tenant's members. The consumer's only job is IdP group membership —
it never distributes keys. CA rotation is dual-trust/zero-lockout ([`../operations/rotation.md`](../operations/rotation.md)).

## §4 · Authorization — group membership → RBAC

Authorization is **OIDC group membership**, mapped to Kubernetes RBAC:

- **Platform/VM tenancy:** the `talu-tenant` chart binds the project's members (`allowedUsers`) to a
  namespace-scoped Role (needs apiserver OIDC wired to actually log in to the management API — most
  consumers only need the SSH/console/usage surfaces, not raw management `kubectl`).
- **Managed clusters (KaaS):** RBAC is on the *tenant's own* apiserver — see §6.

The consumer provisions the group and its membership; Talu maps membership to capability. It never
receives a callback to authorize an action.

## §5 · VM console — VNC

Browser VNC to a VM is the **virt-api VNC subresource**, reached through Pomerium via a per-tenant
ServiceAccount scoped to that namespace's `virtualmachineinstances/vnc`. The console is another
Pomerium/OIDC route — same sign-in, no separate credential. `vms.<domain>` (kubevirt-manager) is the
platform console; a consumer can also mint the subresource URL directly.

## §6 · Managed Kubernetes (KaaS)

A tenant can get its **own Kubernetes cluster** on the same substrate. It integrates through the *same
four verbs* as a VM tenant — the differences are the chart, the status objects, and one extra metering
component. Architecture: [`../architecture/kaas.md`](../architecture/kaas.md); operator runbook:
[`../operations/kaas-deploy.md`](../operations/kaas-deploy.md).

### Provision (WRITE)
A managed cluster is a **`HelmRelease` referencing the [`talu-cluster`](../../components/tenancy/cluster-chart/)
chart** — its **`values.schema.json` is the API**, mirroring `talu-tenant`. The consumer sets:

| Value | Meaning |
|---|---|
| `name`, `projectUuid` | cluster name + the join key stamped on every object |
| `debugPublicKey` | operator break-glass SSH key baked into workers (required) |
| `kubernetesVersion` | tenant k8s (≤ min(mgmt, newest capk image)) |
| `controlPlane.replicas`, `workers.{replicas,cores,memory}` | CP + worker sizing |
| `workers.autoscaling.{enabled,min,max}` | node autoscaling (`min ≥ 1`) |
| `dataStore` | dedicated per-tenant etcd (default) or `default` (shared) |
| `wiring.enabled`, `wiring.inTenant.adminUser` | render CSI/CCM/in-tenant RBAC; who gets cluster-admin |
| `backup.inTenant.*` | in-tenant Velero DR (optional) |

Substrate prerequisites the consumer **assumes exist** (the operator provides them, not the consumer):
CAPI providers + `EXP_CLUSTER_RESOURCE_SET`, Rook-Ceph `ceph-block`, Cilium LB-IPAM, and — for a
dedicated datastore — a `kamaji-etcd` DataStore named `<name>-local`.

### Watch (STATUS)
Readiness is ordinary CR `.status`, watchable directly or via Prometheus:

| Signal | Object `.status` | Prometheus (from `ksm-crs.yaml`) |
|---|---|---|
| Cluster settled | `Cluster.status.phase == "Provisioned"` | `talu_kaas_cluster_phase_info{phase="Provisioned"}` |
| Control plane up | `TenantControlPlane .status.kubernetesResources.version.status == "Ready"` | `talu_kaas_cluster_info{ready="True"}` |
| Workers joined | `MachineDeployment .status.readyReplicas == spec.replicas` | `talu_kaas_workers_ready` / `talu_kaas_workers_desired` |
| API endpoint | `TenantControlPlane .status.controlPlaneEndpoint` | `talu_kaas_cluster_info{endpoint=…}` |
| API reachable | — | `probe_success{probe_type="tenant-apiserver"}` (blackbox) |

### Read — usage → billing (PROMETHEUS)
Managed clusters have their own recording rules ([`kaas-usage-rules.yaml`](../../components/platform/monitoring/kaas-usage-rules.yaml)),
because a hosted control plane is **pods, not VMs**, so the VM `talu:tenant_*` rules miss it. Per
`kaas-<name>` namespace:

- `talu:kaas_controlplane_cpu_cores:requested` / `…_memory_bytes:requested` — the hosted apiserver/CM/
  scheduler/konnectivity + per-tenant CSI/CCM/autoscaler overhead (the cost beyond the tenant's VMs).
- `talu:kaas_worker_vcpu_cores:allocated` / `…_memory_bytes:allocated` / `talu:kaas_worker_count` — the
  worker VMs.
- `talu:kaas_storage_bytes:requested` — tenant PVCs (kubevirt-csi backing volumes).
- `talu:kaas_project_uuid:info` — joins each namespace to `talu.io/project-uuid` (the KaaS analog of
  `talu:tenant_project_uuid:info`).

**Caveat:** a *dedicated* per-tenant etcd runs as `etcd-<name>-*` in `kamaji-system` (not the tenant
namespace), so its cost is outside these sums — attribute it by release name if you bill it separately.
€-conversion stays in the orchestrator.

### Delegate — kubectl access
The tenant apiserver has its own TLS/authn, so it does not traverse Pomerium's HTTP proxy; instead a
Pomerium **kubectl route** authenticates the user against the same IdP and forwards with
`Impersonate-User` headers (validated: SA token alone → 403; token + impersonation → 200). Authority
comes from the in-tenant RBAC the chart seeds — `wiring.inTenant.adminUser` → `cluster-admin`, and an
opt-in per-user OIDC binding on the tenant apiserver. The tenant user needs **no static credential**:

```sh
pomerium-cli k8s exec-credential https://<name>.<domain>   # wired via a kubeconfig exec plugin
```

The multi-cluster console **Headlamp** (`clusters.<domain>`) auto-discovers new tenants. Details:
[`../operations/kaas-deploy.md`](../operations/kaas-deploy.md) §4.

### Delete (GC)
Deleting the `HelmRelease` (or the `Cluster`) garbage-collects the whole tenant cluster — Machines,
worker VMIs, DataVolumes, the hosted control plane, and the released LB IP — and it drops off Headlamp
within a reconcile interval. The consumer watches `talu_kaas_cluster_phase_info` disappear. Remove the
dedicated etcd + DataStore + Garage buckets separately if they were provisioned.

## What a consumer must NOT assume

- **Declarative objects only** — no imperative side channels; write, then watch `.status`.
- **Labels are truth, names are handles** — join on `talu.io/project-uuid`.
- Talu may run with **no orchestrator at all** — never design objects that require one to exist.
