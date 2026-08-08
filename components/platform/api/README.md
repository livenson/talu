# `talu-apiserver` — the typed Talu API (OFF BY DEFAULT)

Serves **`tenancy.talu.io/v1alpha1`** as a projection over Flux `HelmRelease`s. Design, rejected
alternatives and the failure modes this must be operated with:
[`docs/architecture/adr-api-layer.md`](../../../docs/architecture/adr-api-layer.md). Source:
[`apiserver/`](../../../apiserver/).

**Applied by the opt-in `phys_api` ansible role** (`phys-stack.yml --tags api`; tagged `never`, so a
normal run never touches it). Before that role existed, everything here was applied by hand — which
meant a rebuilt lab would have had none of it, and a stale `PrometheusRule` silently monitored a
metric that no longer existed. That was only caught by proving an alert actually fires; "rules load,
`health=ok`" was not the same thing.

**Nothing here is referenced by any environment overlay.** This is Phase 1 of the ADR — additive and
opt-in: both the typed API and hand-written `HelmRelease`s write the same objects, so a site adopts it
by applying this directory and removes it by deleting the `APIService`.

## Before enabling, know the failure mode

An unavailable `APIService` degrades the **whole cluster**, not just Talu: discovery fails, and
[no namespace anywhere finishes terminating](https://github.com/kubernetes/kubernetes/issues/119662).
That is the price of aggregation (ADR §5). Mandatory before a production site turns this on:

- the `PodDisruptionBudget` + 2 replicas + anti-affinity in `deployment.yaml` (all included here);
- an alert on `aggregator_unavailable_apiservice{name="v1alpha1.tenancy.talu.io"}`;
- the **break-glass**, which works precisely because this server stores nothing:

  ```sh
  kubectl delete apiservice v1alpha1.tenancy.talu.io
  ```

  Full cluster function returns immediately, and no tenant state is lost — the `HelmRelease`s are the
  real state and Flux keeps reconciling them.

## Status — served through aggregation, validated 2026-08-06

Deployed in-cluster on rocky-phys and driven with **plain `kubectl`**, through the aggregation layer:

- `APIService v1alpha1.tenancy.talu.io` → **Available=True**, cainjector filled the `caBundle`;
- `kubectl api-resources --api-group=tenancy.talu.io` lists `Tenant`, and **`kubectl explain
  tenant.spec` works** — the generated OpenAPI paying off;
- `kubectl apply -f tenant.yaml` → backing `HelmRelease` Ready → the tenant namespace rendered with
  `talu.io/project-uuid`;
- `kubectl patch tenant` propagated into the HelmRelease's values (the Update verb);
- `kubectl delete tenant` removed the release and the namespace;
- **ownership holds**: `kubectl get tenants -A` reports `No resources found` on a cluster running four
  hand-written tenants, which is the point — the typed API cannot see, mutate or delete them.

### Watch and printer columns (added 2026-08-06)

Both gaps the first in-cluster run surfaced are closed:

```
$ kubectl get tenants -n tenants
NAME    PROJECT                                PHASE   MEMBERS   AGE
wtest   eeeeeeee-1111-2222-3333-444444444444   Ready   2         25s
```

`kubectl get tenants --watch` streams the real lifecycle — **`Pending → Provisioning → Ready →
Deleting`** — and `kubectl delete` no longer spams `watch is not supported`.

Two notes on the projection:

- A tenant being torn down reports **`Deleting`**, not `Degraded`. The backing HelmRelease's `Ready`
  condition goes `False` while helm uninstalls, so the deletion timestamp is checked first.
- **The stream is chatty**: every HelmRelease status write becomes an event, and Flux writes status
  often, so a client sees many more events than semantic changes. Correctness is unaffected (each
  event carries the current projection); de-duplicating would need a per-connection cache.

### All three kinds are served (2026-08-06)

`Tenant`, `TenantVM` and `ManagedCluster`. A `TenantVM` lives in the **tenant's**
namespace while its backing release sits in the management namespace as `<tenant>-<vm>` — the same
name the tenancy role generates, so the typed API and the Git path produce identical objects. It
inherits `projectUuid` and the member list from its Tenant and is refused outright in a namespace no
Tenant owns.

**Why `TenantVM` and not `VirtualMachine`:** `kubevirt.io/VirtualMachine` already registers the
plural `virtualmachines` **and** the short names `vm`/`vms` on this very substrate, so a Talu kind by
either name is shadowed by the thing it is built on — `kubectl get vms` silently returns *KubeVirt's*
objects. `VM` would have been worse than `VirtualMachine`, not better: `vms` is the shortcut kubectl
expands before it ever consults our resource. Same reasoning that made the KaaS kind `ManagedCluster`
rather than `Cluster`. Short name: `tvm`.

One operational note: a kind rename is **not instant for clients**. Our server serves the new name
immediately, but kube-apiserver caches each `APIService`'s discovery document, so `kubectl` kept
reporting `no matches for kind "TenantVM"` for a short while (it refreshed in ~10s here). Expect the
same lag for any future kind change.

**`ManagedCluster` is exercised too** (2026-08-07): the `talu-cluster` chart is now published
alongside the other two, and creating a `ManagedCluster` through the API rendered **real CAPI
objects** — `Cluster`, `KamajiControlPlane` and `MachineDeployment` in a dedicated `kaas-<name>`
namespace — with `memoryGiB: 4` mapped to the chart's `memory: "4Gi"`. Deleting it garbage-collected
them.

Two things that cost time and are worth knowing:

- **The cluster chart is independently versioned** (0.3.0, while tenant/vm are at 0.1.0). `helm push`
  tags by the chart's own version, so an `OCIRepository` ref pinned to the wrong tag silently never
  resolves.
- **Deleting the tenant namespace out from under a HelmRelease strands it**: helm's uninstall cannot
  finish, so the release sits in `Terminating` on its finalizer. Delete the `ManagedCluster` and let
  Flux GC the namespace, rather than removing the namespace yourself.

## Monitoring

`talu_api_info` and `talu_api_ready` come from kube-state-metrics, read from the **backing
HelmRelease** — not from `tenancy.talu.io`.

**Why not the typed kinds directly:** KSM's CustomResourceState is **CRD-driven**. Upstream states it
"watches the installed CRDs for this purpose", requires `list`/`watch` on
`customresourcedefinitions`, and explicitly *discourages* CRS for objects without a CRD. Our kinds are
served by an aggregated apiserver and have no CRD object, so CRS **silently drops them** — no error,
no metrics, which is what made this expensive to diagnose. No amount of RBAC or config fixes it.

`HelmRelease` is a CRD, and the API server already stamps `talu.io/kind`, `talu.io/tenant`,
`talu.io/vm` and `talu.io/project-uuid` onto it, so the consumer vocabulary is recoverable from
labels. Two things make this **better** than reading the typed objects would have been:

- the series **survive an `APIService` outage**, so "a tenant is not reconciling" cannot be blinded by
  the layer it monitors;
- they cover **Git-managed tenants** as well, which carry `talu.io/tenant` but never `talu.io/kind`.

`TaluTenantDegraded` / `TaluTenantVMDegraded` alert on `talu_api_ready{status="False"}`, split by
whether the `vm` label is set.

⚠ **A CRS change needs kube-state-metrics restarted.** Helm rewrites the ConfigMap but does not roll
the Deployment, so KSM keeps serving the config it parsed at startup and new metrics silently never
appear — same class as the Cilium `cilium-config` trap in lab-notes. `phys_monitoring` now does the
rollout restart.

## Regenerating the OpenAPI definitions

`apiserver/pkg/generated/openapi/` is **generated and committed**. Re-run
`apiserver/hack/update-codegen.sh` after any change to `pkg/apis/**/types.go`: apiserver 0.34 refuses
to start without an OpenAPI v3 config, and it is built from that map, so a stale map is a **boot
failure**, not a documentation problem.

## Image

`apiserver/Containerfile` builds a static binary into `scratch`. The image must live in a registry the
**nodes** can pull from, and the seven per-upstream mirrors are pull-through caches that reject
pushes with a bare `500`.

The lab solves this with a **local pushable registry** (`phys_registry_mirror`, port 5010) plus one
extra `machine.registries.mirrors` entry mapping the private name `talu.registry` to it — so the
image is referenced as `talu.registry/talu-apiserver:0.1.0`. That Talos change applies **without a
reboot** (`--mode=no-reboot`), which matters on a lab with no console or BMC; all four nodes stayed
`Ready` through it.

A site with its own registry just sets `image:` in `deployment.yaml` and skips all of this.
