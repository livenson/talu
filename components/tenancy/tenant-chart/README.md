# talu-tenant chart

The **manager-agnostic tenant API**. A tenant — and every VM it owns — is a **values file**
(`environments/<site>/tenants/<slug>.yaml`), reconciled by Flux. Nothing structural changes when a
tenant or VM is added; it's a values-PR. Every rendered object carries `talu.io/project-uuid`, the
join key any external orchestrator reconciles on.

## What it renders (from `values.yaml`)

| Template | Objects | Purpose |
|---|---|---|
| `namespace.yaml` | `Namespace` (PSA privileged) + default `ResourceQuota` | the tenant boundary + metering envelope |
| `vms.yaml` | per VM: cloud-init `Secret` (`secretRef`), `VirtualMachine` (+ `DataVolume` when `source: dataSource`), ssh `Service`, `CiliumNetworkPolicy` | the VMs + their disk + SSH plumbing |
| `rbac.yaml` | `Role` + `RoleBinding` (tenant members) | scoped namespace access (needs apiserver OIDC to log in) |
| `ippool.yaml` | `CiliumLoadBalancerIPPool` (when `internalIpPool` set) | tier-1 stable internal IPs |
| `securitygroups.yaml` | `CiliumNetworkPolicy` per `securityGroups` entry | cloud-style ingress/egress rules |
| `dashboards.yaml` | `prom-label-proxy` + per-tenant `Perses` + datasource + `PersesDashboard` + CNP (when `dashboards.enabled`) | a namespace-scoped metrics dashboard, Pomerium-fronted |

The VM Service is labelled `talu.io/ssh-expose: "true"` and annotated `talu.io/allowed-users`, which
the Pomerium route renderer (`components/platform/access/`, `dev/lab/expose-vm.sh`) turns into an
`ssh://<vm>` route scoped to the tenant's members. **SSH is Pomerium Native SSH** — no OpenBao.

## Root disk source (`defaults.source`, per-VM overridable)

- **`containerDisk`** (default) — ephemeral, boots straight from a registry image (`image:`); reset on
  restart. Works with **no golden-image catalog** (standalone-first). See `tenants/acme.yaml`.
- **`dataSource`** — opt-in. Persistent `DataVolume` cloned from a golden-image **`DataSource`**
  (`dataSource`/`dataSourceNamespace`, size `rootDiskSize`). New VMs get the latest patched image
  automatically (a CDI `DataImportCron` rolls the DataSource), and the disk persists so **bootc
  self-update** sticks. Requires `components/infrastructure/cdi/` + `zot`. See `tenants/beta.yaml`.

Set `dashboards.enabled: true` to render a per-tenant Perses + prom-label-proxy stack (overview + per-VM
detail), reachable only via Pomerium — see the `dashboards.yaml` row above and `tenants/beta.yaml`.

## Render / apply

```sh
# CA pubkey comes from the cluster (never duplicated in Git):
CAPUB=$(kubectl -n pomerium get cm pomerium-user-ca -o jsonpath='{.data.user_ca\.pub}')
helm template <slug> components/tenancy/tenant-chart \
  -f environments/<site>/tenants/<slug>.yaml --set sshUserCaPubKey="$CAPUB" | kubectl apply -f -
```

## Flux wiring (production)

Mirror `components/infrastructure/cilium/` — one `HelmRelease` per tenant, `valuesFrom` the tenant
values file, and `sshUserCaPubKey` injected from the `pomerium-user-ca` ConfigMap:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: tenant-acme, namespace: flux-system }
spec:
  chart:
    spec: { chart: ./components/tenancy/tenant-chart, sourceRef: { kind: GitRepository, name: talu } }
  valuesFrom:
    - kind: ConfigMap
      name: pomerium-user-ca            # maps user_ca.pub -> sshUserCaPubKey
      valuesKey: user_ca.pub
      targetPath: sshUserCaPubKey
  values: { }                            # + the tenant's acme.yaml values
```

## Validated (rocky-sandbox)

`environments/rocky-sandbox/tenants/acme.yaml` renders 8 kinds (project-uuid on all), applies clean,
the `app1` VM reaches Running, the `ResourceQuota` tracks usage, and the chart's `allowed-users`
annotation drives a per-tenant `ssh://app1` Pomerium route (`in: [alice@talu.local]`) — alongside two
other tenants, each isolated. This is the same bundle `dev/lab/gen-vm-manifests.sh` emits, now
values-driven and Flux-reconcilable.
