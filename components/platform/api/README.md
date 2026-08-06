# `talu-apiserver` — the typed Talu API (OFF BY DEFAULT)

Serves **`tenancy.talu.io/v1alpha1`** as a projection over Flux `HelmRelease`s. Design, rejected
alternatives and the failure modes this must be operated with:
[`docs/architecture/adr-api-layer.md`](../../../docs/architecture/adr-api-layer.md). Source:
[`apiserver/`](../../../apiserver/).

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

`VirtualMachine` and `ManagedCluster` are still not served.

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
