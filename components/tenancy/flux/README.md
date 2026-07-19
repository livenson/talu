# tenancy/flux — HelmRelease-per-tenant wiring

A tenant/VM is a **`HelmRelease`** that an orchestrator `kubectl apply`s **directly to the API**
(no Git). Flux's helm-controller renders it via the `talu-tenant` chart; `HelmRelease.status` is the
single object the manager watches. This mirrors Cozystack's backing mechanism (chart + HelmRelease),
minus the aggregation apiserver.

## Pieces
- `oci-registry.yaml` — a small in-cluster OCI registry the platform pushes the chart to (production:
  swap for the adopter's registry, or a `GitRepository`/`HelmRepository` source).
- `ocirepository.yaml` — the Flux `OCIRepository` source pulling `talu-tenant` (ClusterIP, `insecure`).
- `helmrelease.example.yaml` — the shape of a tenant instance the orchestrator writes.
- `route-sync.yaml` — CronJob that renders the Pomerium `ssh://<vm>` routes from `talu.io/ssh-expose`
  Services (the one cross-cutting bit no chart/HelmRelease can own — a shared-config edit).

## Publish the chart (platform, once)
```sh
helm package components/tenancy/tenant-chart -d /tmp
# push from INSIDE the cluster (the in-cluster registry ClusterIP is the reliable path):
kubectl -n flux-system run helmpush --image=alpine/helm --restart=Never --command -- sleep 300
kubectl -n flux-system cp /tmp/talu-tenant-0.1.0.tgz helmpush:/tmp/c.tgz
kubectl -n flux-system exec helmpush -- helm push /tmp/c.tgz oci://registry.flux-system.svc:5000/charts --plain-http
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
