# tenancy/flux — HelmRelease-per-tenant wiring

A tenant/VM is a **`HelmRelease`** that an orchestrator `kubectl apply`s **directly to the API**
(no Git). Flux's helm-controller renders it via the `talu-tenant` chart; `HelmRelease.status` is the
single object the manager watches. This mirrors Cozystack's backing mechanism (chart + HelmRelease),
minus the aggregation apiserver.

**Upstream:** [Flux `HelmRelease`](https://fluxcd.io/flux/components/helm/helmreleases/) · [`OCIRepository`](https://fluxcd.io/flux/components/source/ocirepositories/) · [Cozystack](https://cozystack.io/docs/) (the pattern's origin).

## Automated (the `tenancy` ansible role)
`ansible-playbook site.yml --tags tenancy` does the whole thing: `flux install` (source + helm
controllers only), applies this component (`kubectl apply -k`), publishes the chart via the in-cluster
`chart-publish` Job, reconciles the `OCIRepository`, mirrors the CA ConfigMap into the `tenants`
namespace, and renders + applies a HelmRelease per `environments/<env>/tenants/*.yaml`. The steps below
are the manual equivalents.

## Pieces
- `oci-registry.yaml` — a small in-cluster OCI registry the platform pushes the chart to (production:
  swap for the adopter's registry, or a `GitRepository`/`HelmRepository` source).
- `ocirepository.yaml` — the Flux `OCIRepository` source pulling `talu-tenant` (ClusterIP, `insecure`).
- `chart-publish-job.yaml` — in-cluster Job: clone repo → `helm package` → `helm push --plain-http`
  (mirrors the pkg-repo publish-job). Applied on-demand by the role, not part of `kustomization.yaml`.
- `helmrelease.example.yaml` — the shape of a tenant instance the orchestrator writes.
- `route-sync.yaml` — CronJob that renders the Pomerium `ssh://<vm>` routes from `talu.io/ssh-expose`
  Services (the one cross-cutting bit no chart/HelmRelease can own — a shared-config edit).

`kustomization.yaml` bundles the registry + `OCIRepository` + `route-sync`. Flux's own controllers are
installed by the role via `flux install` (upstream manifests), not kustomize.

## Publish the chart manually (if not using the role)
```sh
kubectl -n flux-system delete job chart-publish --ignore-not-found
kubectl apply -f components/tenancy/flux/chart-publish-job.yaml
kubectl -n flux-system wait --for=condition=complete job/chart-publish --timeout=200s
flux reconcile source oci talu-tenant --namespace flux-system
```

## Create a tenant (orchestrator)
`kubectl apply` a `HelmRelease` (see `helmrelease.example.yaml`); watch `.status.conditions[Ready]`;
delete it → Flux GC removes the whole tenant bundle. The Pomerium User CA is injected via
`valuesFrom` (ConfigMap `pomerium-user-ca`, mirrored into the HelmRelease's namespace).

## Lab status — VALIDATED end-to-end (2026-07-19)
`kubectl apply` of the acme `HelmRelease` → **`HelmRelease Ready=True` ("Helm install succeeded")** →
Flux rendered the full tenant bundle (cloud-init Secret, VirtualMachine **app1 Running**, ssh Service,
`app1-ssh-pin` + `sg-web` CiliumNetworkPolicies, ResourceQuota, Role) with the CA pubkey injected via
`valuesFrom`. The orchestrator flow proven: one object applied directly to the API, one `.status` to watch.

Two real bugs were fixed getting here (NEITHER was "the node is too small" — see docs/development/lab-notes.md #25):
(1) a chart bug — the CA pubkey's trailing newline broke the double-quoted YAML (`| trim | quote` fixes
it; `helm template` missed it because `$(...)` strips newlines, Flux `valuesFrom` doesn't); (2) the
nested CNI false-negatived source-controller's readiness probe, dropping it from its Service endpoints
so helm-controller couldn't fetch the chart. The earlier pids-limit 2048 wall was separate and real.

## Re-validated via the automation (2026-07-22)
The `tenancy` role reproduces the round-trip end-to-end: `flux install` → chart published to the
registry → `OCIRepository Ready` → acme HelmRelease → **`Ready=True` ("Helm install succeeded")** →
VM `app1 Running` with quota/Role/CiliumNetworkPolicy/ssh-Service rendered into the `acme` namespace.
Two nested-node/Flux gotchas were found and are now handled by the role (details:
docs/development/lab-notes.md **#36**, **#37**): the Flux controllers' host→pod probes time out on the
nested node (distroless images → the role removes the probes), and Flux merges `spec.values` after
`valuesFrom` (so the role strips the tenant files' `sshUserCaPubKey: ""` placeholder — it would
otherwise override the CA injection).
