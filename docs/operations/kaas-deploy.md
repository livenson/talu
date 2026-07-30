# Deploying & accessing a managed Kubernetes (KaaS) tenant cluster

Operator runbook for the **KaaS layer** — provisioning a tenant Kubernetes cluster and giving a tenant
`kubectl` + console access. Architecture and the "why": [`../architecture/kaas.md`](../architecture/kaas.md).
Every step below was validated end-to-end on the physical lab (2026-07-30).

A tenant cluster is **one Helm values file** rendered through the
[`talu-cluster` chart](../../components/tenancy/cluster-chart/) — a hosted control plane (Kamaji pods)
plus KubeVirt worker VMs, wired to the shared substrate (Ceph storage, Cilium LB-IPAM, Pomerium SSO).

---

## 1. Prerequisites (management cluster, once)

| Prereq | How | Check |
|---|---|---|
| CAPI + providers | `clusterctl init --bootstrap kubeadm --control-plane kamaji --infrastructure kubevirt --addon helm` | `kubectl get pods -n capi-system` |
| **`ClusterResourceSet` feature gate** | `EXP_CLUSTER_RESOURCE_SET=true` at init, or patch `capi-controller-manager`'s `--feature-gates` to add `ClusterResourceSet=true` | `kubectl -n capi-system get deploy capi-controller-manager -o jsonpath='{..args}' \| grep ClusterResourceSet` |
| Storage | Rook-Ceph RBD `StorageClass` (`ceph-block`) | `kubectl get sc` |
| Networking | Cilium with `socketLB.hostNamespaceOnly: true` + LB-IPAM pool | tenant API/LB IPs come from the pool |
| Datastore | either the shared `kamaji-etcd` (`DataStore` `default`) or a **dedicated** per-tenant `kamaji-etcd` on local-path (production default — ~50× lower fsync) | `kubectl get datastore` |

> **The CRS gate is load-bearing.** Without `ClusterResourceSet=true` the in-tenant manifests
> (CSI node plugin, Pomerium RBAC, the admin binding) are never applied — the control plane comes up
> but the tenant has no CSI/access. This was the one lab prereq that had to be flipped on.

---

## 2. Deploy a tenant cluster

Write a values file (dedicated etcd omitted here → shared `default`; for production set `dataStore: ""`
and pre-create the per-tenant `kamaji-etcd`):

```yaml
# tenant-b.yaml
name: tenant-b
projectUuid: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff"   # the manager join key, on every object
dataStore: "default"                 # or "" for a dedicated per-tenant etcd (production default)
kubernetesVersion: v1.34.1           # ≤ min(mgmt, newest quay.io/capk containerdisk)
controlPlane: { replicas: 2 }        # CP pods spread across nodes → survive a mgmt-node loss
workers:      { replicas: 2, cores: 4, memory: 8Gi }
debugPublicKey: "ssh-ed25519 AAAA... operator@host"   # break-glass into worker VMs (REQUIRED)
wiring:
  enabled: true                      # render the CSI/CCM/in-tenant wiring (graduated F1 path)
  csi:      { infraStorageClass: ceph-block }
  inTenant: { adminUser: "alice@talu.local" }   # gets cluster-admin in the tenant
```

Render and apply (Flux/GitOps is the production path; direct is fine for the lab):

```sh
helm template tenant-b components/tenancy/cluster-chart -f tenant-b.yaml | kubectl apply -f -
```

**What gets created** (namespace `kaas-<name>`, e.g. `kaas-tenant-b`):
- *Declarative:* `Cluster` + `KubevirtCluster`, `KamajiControlPlane`, `MachineDeployment` (+
  `KubevirtMachineTemplate`, `KubeadmConfigTemplate`), `MachineHealthCheck`, and a Cilium `HelmChartProxy`.
- *Wiring (`wiring.enabled`):* the `kubevirt-csi` controller + `cloud-provider-kubevirt`, each **mounting
  the Kamaji-published `<name>-admin-kubeconfig` Secret directly** (`admin.conf` → `value`), and a
  `ClusterResourceSet` carrying the in-tenant manifests.

> **The graduation insight (no imperative step):** the CSI/CCM pods are created immediately but sit
> `Pending`/`ContainerCreating` until Kamaji publishes `<name>-admin-kubeconfig` (a few seconds after
> the control plane is up), then start on their own. Pure eventual consistency — there is no
> post-provision `kubectl … --kubeconfig` step.

---

## 3. Verify

```sh
NS=kaas-tenant-b
kubectl -n $NS wait --for=jsonpath='{.status.kubernetesResources.version.status}'=Ready tcp/tenant-b --timeout=120s
kubectl -n $NS get pods | grep -E 'csi-controller|cloud-provider'   # both Running (mounted the Secret)
kubectl get clusterresourcesetbinding -n $NS                        # tenant-b binding present

# tenant-side (Kamaji publishes an admin kubeconfig; use it read-only to inspect)
kubectl -n $NS get secret tenant-b-admin-kubeconfig -o jsonpath='{.data.admin\.conf}' | base64 -d > /tmp/tb.kc
TK="kubectl --kubeconfig=/tmp/tb.kc"
$TK get nodes                                    # worker(s) Ready (~5 min on first Cilium image pull)
$TK get ds -n kubevirt-csi-driver kubevirt-csi-node   # applied by the CRS
$TK get clusterrolebinding | grep talu-admin     # the admin binding for adminUser
```

Storage smoke (tenant PVC → infra Ceph PVC, all via the direct-mounted CSI controller):

```sh
$TK apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: csi-test }
spec: { accessModes: [ReadWriteOnce], storageClassName: kubevirt, resources: { requests: { storage: 1Gi } } }
EOF
$TK get pvc csi-test        # → Bound; a matching pvc-… appears on ceph-block in $NS
```

> **First-worker join takes ~5 min** — the worker VM pulls the ~200 MB Cilium agent image over its
> masqueraded path before CNI initializes and the node goes `Ready`. `NotReady` with
> `NetworkPluginNotReady` during that window is expected, not a fault.

---

## 4. Access

Two independent surfaces, both gated by the **same Pomerium/Dex SSO** as the rest of Talu.

### 4a. `kubectl` — Pomerium impersonation route

The tenant API server has its own TLS + authn, so it does **not** traverse Pomerium's HTTP proxy.
Instead a Pomerium **kubectl route** authenticates the user against the shared IdP and forwards the
request to the tenant API with `Impersonate-User` headers. Two layers:

- **Who** can reach the API — the Pomerium route policy (the tenant's members).
- **What** they can do — tenant RBAC. The `ClusterResourceSet` seeds a `pomerium` ServiceAccount with
  *only* impersonate permission, and binds `adminUser` to `cluster-admin`. The SA token alone is
  powerless; authority comes only from the impersonation headers Pomerium sets from the authenticated
  session. **Validated:** SA token alone → `403`; SA token + `Impersonate-User: alice@…` → `200`.

**Add the route** (the one edit the chart does not render — it lives in the shared `pomerium-config`
blob, owned by `route-sync`; on the lab the `phys_kaas_tenant` role's `patch-pomerium-route.py` does it):

```sh
EP=$(kubectl -n $NS get tcp tenant-b -o jsonpath='{.status.controlPlaneEndpoint}')   # e.g. 172.18.200.1:6443
# add an https://tenant-b.<domain> kubectl route → $EP, with the tenant CA + the pomerium SA token,
# allowed_users = the tenant members, then restart Pomerium.
```

**Tenant user** then needs no static credential — `kubectl` gets a short-lived cert from Pomerium:

```sh
pomerium-cli k8s exec-credential https://tenant-b.<domain>   # wired via a kubeconfig exec plugin
kubectl --context tenant-b get pods -A
```

### 4b. Console — Headlamp

**Headlamp** at `https://clusters.<domain>` (admin-only, behind Pomerium/Dex SSO) is the multi-cluster
console over the tenant clusters. A `cluster-sync` reconciler merges each `<tenant>-admin-kubeconfig`
Secret into Headlamp's config every ~2 min, so a newly provisioned tenant **appears automatically** and
a deleted one drops off. Drill into any tenant to browse its workloads. Role: `phys_headlamp`. See
[`../architecture/kaas.md`](../architecture/kaas.md) § Console.

---

## 5. Backup / DR

- **Control plane (etcd):** the mgmt-side `kaas-etcd-snapshot` CronJob snapshots every tenant's
  `kamaji-etcd` DataStore to Garage every 15 min (RPO 15 min). Nothing per-tenant to configure.
  Component: [`../../components/tenancy/kaas-backup/`](../../components/tenancy/kaas-backup/).
- **Workload + PVC data:** enable `backup.inTenant` in the values to install in-tenant Velero
  (node-agent on the worker VMs) → Garage. Requires the Garage S3 endpoint reachable from the tenant
  (`components/platform/backup/garage-lb.yaml` — validated: LB-IPAM gave it `172.18.200.2`), a
  per-tenant bucket, and the `velero-garage` creds Secret in the tenant. Restore tiers + drills: the
  kaas-backup README and [`../development/kaas-test-plan.md`](../development/kaas-test-plan.md) (KT-33/34/35).
  - **Egress requirement (lab finding):** the addon provider (CAAPH) installs the chart from
    `https://vmware-tanzu.github.io/helm-charts`, so the **management cluster** needs egress to it (or a
    mirror). On the physical lab that host timed out while `helm.cilium.io` worked — so the HCP is
    accepted and configured correctly but the install stalls at chart fetch. In a restricted network,
    mirror the velero chart and override the repo URL per environment.

---

## 6. Teardown

```sh
kubectl delete cluster tenant-b -n kaas-tenant-b       # CAPI GCs Machines/VMIs/DataVolumes/CP/LB IP
kubectl delete ns kaas-tenant-b                         # after the cluster is gone
# then remove the Pomerium route and, if dedicated, the per-tenant kamaji-etcd + DataStore + Garage bucket.
```

Deleting the `Cluster` cascades to the workers (VMIs, DataVolumes) and releases the LB IP; the tenant
drops off Headlamp within a reconcile interval.
