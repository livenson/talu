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

## Image

`apiserver/Containerfile` builds a static binary into `scratch`. The image must live in a registry the
**nodes** can pull from; the lab's per-upstream mirrors are pull-through caches and cannot be pushed
to, so a site needs either a pushable registry trusted by Talos (`machine.registries`) or a public one.
Set it in `deployment.yaml` (`image:`).
