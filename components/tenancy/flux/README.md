# tenancy/flux — HelmRelease-per-tenant wiring

A tenant/VM is a **`HelmRelease`** that a manager (Waldur) `kubectl apply`s **directly to the API**
(no Git). Flux's helm-controller renders it via the `talu-tenant` chart; `HelmRelease.status` is the
single object the manager watches. This mirrors Cozystack's backing mechanism (chart + HelmRelease),
minus the aggregation apiserver.

## Pieces
- `oci-registry.yaml` — a small in-cluster OCI registry the platform pushes the chart to (production:
  swap for the adopter's registry, or a `GitRepository`/`HelmRepository` source).
- `ocirepository.yaml` — the Flux `OCIRepository` source pulling `talu-tenant` (ClusterIP, `insecure`).
- `helmrelease.example.yaml` — the shape of a tenant instance Waldur writes.
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

## Create a tenant (manager / Waldur)
`kubectl apply` a `HelmRelease` (see `helmrelease.example.yaml`); watch `.status.conditions[Ready]`;
delete it → Flux GC removes the whole tenant bundle. The Pomerium User CA is injected via
`valuesFrom` (ConfigMap `pomerium-user-ca`, mirrored into the HelmRelease's namespace).

## Lab status (2026-07-18)
Validated: the `talu-tenant` chart renders/applies a working tenant (namespace, quota, RBAC, VM,
Service, pinning, securityGroup CNP — `helm template | kubectl apply` brought `app1` to Running);
Flux installs; the `OCIRepository` source goes **Ready=True**; helm-controller **picks up and
reconciles** the tenant `HelmRelease`. NOT completed on the lab: the final chart-artifact fetch —
blocked by the nested single-node's **resource/networking ceiling** (see CLAUDE.md #25: pids-limit,
probe timeouts, pod→service `no route to host` under thread saturation). The design is standard Flux
and reproduces on a non-nested node; the lab simply can't hold the full stack + Flux + a tenant at once.
