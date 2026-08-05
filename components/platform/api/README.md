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

## Status — the API serves (validated 2026-08-05)

Validated by running the binary against the phys cluster with `--kubeconfig` (no in-cluster image
needed, see below):

- **discovery** — `GET /apis/tenancy.talu.io/v1alpha1` returns the `tenants` resource;
- **RBAC is real** — an unauthenticated request gets `403 forbidden: User "system:anonymous"`,
  i.e. delegated authz is doing the work, not a bypass;
- **ownership holds** — `list` returns **0** items against a cluster with four hand-written
  `HelmRelease`s, because they lack `talu.io/managed-by-api`. The typed API cannot see, mutate or
  delete a Git-managed tenant;
- **the full loop closes** — creating a `Tenant` produced a labelled `HelmRelease`, Flux rendered the
  chart, and the `apitest` namespace appeared carrying `talu.io/project-uuid`. Reading it back showed
  `phase: Ready` with members and quota round-tripped;
- **delete** removed the release and the namespace (allow for Flux's finalizer — the object sits in
  `Terminating` while helm uninstalls, so an immediate check looks like a no-op).

Not yet proven: **in-cluster aggregation** (the `APIService`, serving certs and cainjector path) —
that still needs the image. `watch` is unimplemented (clients poll), and `VirtualMachine` /
`ManagedCluster` are not served yet.

Running it outside a pod, which is how all of the above was checked:

```sh
talu-apiserver --kubeconfig=$KUBECONFIG \
  --authentication-kubeconfig=$KUBECONFIG --authorization-kubeconfig=$KUBECONFIG \
  --secure-port=8443 --cert-dir=/tmp/apicerts --audit-log-path=-
```

## Regenerating the OpenAPI definitions

`apiserver/pkg/generated/openapi/` is **generated and committed**. Re-run
`apiserver/hack/update-codegen.sh` after any change to `pkg/apis/**/types.go`: apiserver 0.34 refuses
to start without an OpenAPI v3 config, and it is built from that map, so a stale map is a **boot
failure**, not a documentation problem.

## Image

`apiserver/Containerfile` builds a static binary into `scratch`. The image must live in a registry the
**nodes** can pull from; the lab's per-upstream mirrors are pull-through caches and cannot be pushed
to, so a site needs either a pushable registry trusted by Talos (`machine.registries`) or a public one.
Set it in `deployment.yaml` (`image:`).
