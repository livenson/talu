# KaaS layer — functional, resilience & performance test plan

Executable test plan for Talu's **Kubernetes-as-a-Service** layer (Kamaji hosted control planes +
Cluster API/KubeVirt workers) on the physical lab (`environments/rocky-phys`). Same discipline as
[`../architecture/performance-testing.md`](../architecture/performance-testing.md): **USE for
resources, RED for services**, percentiles never averages, one variable at a time, and every fault
test states a *time-bound* recovery criterion so "it eventually came back" is not a pass.

**Priority is section 2 (resilience).** The KaaS layer's value proposition is that a tenant's
Kubernetes survives management-plane churn; nothing else matters if that is untrue. Resilience tests
are ordered **smallest blast radius first** so a failure stops the run before it costs a wider outage.

---

## 0. System under test, conventions, and safety

### 0.1 Topology recap (what each test can break)

| Layer | Where it lives | Blast radius if it dies |
|---|---|---|
| Tenant CP pods (apiserver/CM/sched/konnectivity ×2) | `kaas-capi`, Deployment `tenant-a` | one tenant |
| Tenant API endpoint | LB-IPAM `172.18.200.1:6443`, Cilium L2 announce | one tenant |
| kubevirt-csi controller | `kaas-capi` (infra side) | one tenant's storage |
| cloud-provider-kubevirt (CCM, LB controller) | `kaas-capi` (infra side) | one tenant's LB Services |
| Worker VMs (2× KubeVirt VMI, containerDisk, `evictionStrategy: External`) | `kaas-capi`, currently both on **talos-cp2** | one tenant's capacity — **not live-migratable** |
| CAPI/CAPK/CAAPH/Kamaji controllers | `capi-*-system`, `kamaji-system` | all tenants' *lifecycle* (not runtime) |
| **kamaji-etcd (shared, 3 replicas, ceph-block)** | `kamaji-system` | **every tenant control plane at once** |
| Management node (`talos-cp2`, libvirt VM on compute2) | compute2 | mgmt N-1 + every tenant object hosted there |

### 0.2 Shell preamble (every test assumes this)

```sh
export KUBECONFIG=/home/cloud-user/talu/talos-phys/kubeconfig     # management cluster
M="kubectl"                                                        # management
clusterctl get kubeconfig tenant-a -n kaas-capi > /tmp/tenant-a.kubeconfig
T="kubectl --kubeconfig=/tmp/tenant-a.kubeconfig"                  # tenant-a
TENANT_API=172.18.200.1:6443
CP2=172.18.1.12                                                    # talos-cp2 (talosctl -n)

# one-time: pin the real label selectors, then hard-code them in your run sheet
$M -n kaas-capi get pods --show-labels
$M -n kamaji-system get pods --show-labels
```

**Tenant-API availability prober** — run in a side terminal for *every* resilience test; it is the
single number most tests are graded on:

```sh
while :; do printf '%s ' "$(date -u +%FT%TZ)"; \
  curl -sk -m 2 -o /dev/null -w '%{http_code} %{time_total}\n' "https://$TENANT_API/readyz" \
  || echo "FAIL"; sleep 1; done | tee -a /tmp/kt-prober.log
```

**Workload-continuity prober** — proves "the control plane broke but the workloads did not":

```sh
$T -n default run nginx --image=nginx --port=80 && $T -n default expose pod nginx --port=80
# from a second tenant pod, in a side terminal:
$T -n default run curler --image=curlimages/curl --restart=Never -- \
  sh -c 'while :; do curl -s -m2 -o /dev/null -w "%{http_code}\n" http://nginx; sleep 1; done'
$T -n default logs -f curler
```

### 0.3 Safety classification

| Class | Meaning | Tests |
|---|---|---|
| **SAFE-NOW** | Single-tenant scope, self-healing, run any time on the live lab | KT-01…KT-20 |
| **ANNOUNCE** | Management-node-scoped blip; run off-hours, tell anyone using the lab | KT-21, KT-22, KT-23, KT-26, KT-27, KT-29 |
| **WINDOW** | Needs a maintenance window; all tenants affected or a node goes down | **KT-24** (etcd quorum loss — stalls *every* TCP), **KT-25** (talos-cp2 reboot) |

> While the lab has only `tenant-a`, KT-24 is *practically* single-tenant — but treat it as WINDOW
> anyway, because the point of the test is the multi-tenant blast radius, and the second tenant
> (`tenant-b`, created in KT-01) must be live for the result to mean anything.

### 0.4 Rules of the run

1. **Baseline first.** Before each test capture: `clusterctl describe cluster tenant-a -n kaas-capi`,
   `$M -n kaas-capi get machine,vmi,pod`, `$T get nodes`, and a screenshot of the **Talu — KaaS**
   Perses dashboard. A test with no before-picture produces no result.
2. **One fault at a time.** Never overlap two KT-xx runs.
3. **Record**: git ref of `capi-tenant-reference.yaml`, deployed `clastix/kamaji:latest` digest (the
   chart is a floating `0.0.0+latest` channel — the digest *is* the version), timestamps, prober log,
   alerts fired.
4. **Abort criteria**: management cluster loses etcd quorum, Ceph goes `HEALTH_ERR`, or a fault does
   not revert within 2× its stated recovery budget → stop, restore, write it up as a defect.
5. **Revert is part of the test.** Every fault has an explicit undo; a test isn't done until the
   system is back at baseline *and* the alert has resolved.

---

## 1. Functional / regression

Runs top-to-bottom as the acceptance gate for any KaaS change (Kamaji digest bump, CAPI/CAPK bump,
tenant k8s version bump). All SAFE-NOW.

### KT-01 — Tenant cluster create from the reference manifest
**Purpose:** the whole KaaS path (Cluster → KamajiControlPlane → LB endpoint → KubevirtMachine →
kubeadm join → Cilium addon) works from a clean apply.
```sh
sed -e 's/tenant-a/tenant-b/g' \
  ansible/roles/phys_kamaji/files/capi-tenant-reference.yaml > /tmp/tenant-b.yaml
# adjust pod/svc CIDRs to be distinct from tenant-a and the management cluster
$M apply -f /tmp/tenant-b.yaml
time $M -n kaas-capi wait --for=condition=Available cluster/tenant-b --timeout=20m
clusterctl describe cluster tenant-b -n kaas-capi
```
**Pass:** `Cluster/Available=True`; `KamajiControlPlane` 2/2 ready; each worker `Machine` reaches
`Running` and its `Node` `Ready`; Cilium `HelmChartProxy` installed; total wall time recorded
(baseline for KT-27). Worker join ≤ **4 min** each (kubeadm's kubelet-health timeout is the hard
ceiling; ~2.5 min is the validated norm).
**Hooks:** `dashboard-kaas` → *Tenant CP pods ready* and *worker VMs running* rise; no
`TenantControlPlaneUnavailable` beyond the initial 2 min.

### KT-02 — Kubeconfig access & the two access paths
**Purpose:** admin kubeconfig works over the LB endpoint, and the konnectivity path
(logs/exec/port-forward) works.
```sh
$T version; $T get nodes -o wide
$T -n default run t --image=busybox --restart=Never -- sleep 3600
$T -n default logs t; $T -n default exec t -- hostname
$T -n default port-forward pod/t 18080:80 &   # expect it to bind
$M -n kaas-capi get svc | grep 6443           # LB IP == status.controlPlaneEndpoint
```
**Pass:** all five verbs succeed; the Service LB IP equals `KamajiControlPlane.status`; no apiserver
cert SAN warnings.

### KT-03 — Scale-out 2 → 3 workers
```sh
$M -n kaas-capi scale machinedeployment tenant-a-md-0 --replicas=3
time $M -n kaas-capi wait --for=jsonpath='{.status.readyReplicas}'=3 machinedeployment/tenant-a-md-0 --timeout=10m
```
**Pass:** new Node `Ready` ≤ **6 min**; existing workloads untouched; no manual Node creation.
**Hooks:** *worker VMs running* +1; no `KaasWorkerVMNotReady`.

### KT-04 — Scale-in 3 → 2 (graceful)
**Pass:** CAPI cordons + drains, VMI deleted, **the tenant `Node` object is garbage-collected
automatically**, workloads rescheduled; ≤ 5 min. Any leftover `Node`/`CSINode` is a **fail**.

### KT-05 — Storage: kubevirt-csi round trip
PVC (SC `kubevirt`, 2Gi) + writer pod (`dd` 64M + `md5sum`); verify the hotplug volume appears in
the VMI's `volumeStatus`; delete + recreate the pod on the *other* worker → same md5 (detach/attach
across nodes); PVC delete releases the infra ceph-block PV.
**Pass:** PVC `Bound` ≤ 60 s; md5 stable; no orphan infra PVC.

### KT-06 — Tenant → management isolation
From a tenant pod: probe the mgmt API VIP (`172.18.0.10:6443`) and mgmt ingress; attempt auth with
the tenant SA token.
**Pass:** tenant workloads hold **no** credential for the management API. With **Layer A**
(`components/platform/network-policy/`, the cluster-wide `egressDeny` to `kube-apiserver`) applied, the
probe must now be a **network DROP** (a Hubble drop record) — not merely a 401 — and a tenant that
writes `egress: 0.0.0.0/0` in its own security group still cannot reach it (deny beats allow). The
kubevirt-csi/CCM credentials live only in `kaas-capi` — confirm no infra kubeconfig Secret is projected
into the tenant.

### KT-07 — Tenant → tenant isolation
With `tenant-b` live: cross-kubeconfig auth must fail (distinct CAs); neither tenant can list the
other's objects; tenant-b cannot reach tenant-a's API endpoint or pod CIDR; kamaji-etcd key prefixes
are tenant-scoped. With the tenant chart's **Layer B baseline** (`networkBaseline.enabled`) on, the
cross-tenant reach must be a **network DROP** (default-deny egress leaves only own-namespace + DNS
allowed) — re-run expecting a Hubble drop record, not just an auth failure.

### KT-08 — Cluster delete & garbage collection
`$M delete cluster tenant-b -n kaas-capi`.
**Pass:** ≤ 10 min: Machines/VMIs/DataVolumes gone; CP Deployment + Service + **LB IP released**;
kamaji-etcd db size returns to ~pre-create; no orphaned PVCs or Helm(Release)Proxies.

### KT-09 — Idempotent re-apply (GitOps drift)
`$M apply -f capi-tenant-reference.yaml` on the live cluster.
**Pass:** no rollout, no Machine churn, no VMI restart; reconcile-error rate stays 0. (Also guards
the CEL trap: `networkProfile` cannot be added to a live TCP.)

---

## 2. Resilience / fault injection — ordered by blast radius, smallest first

Every test: **kill → observe → time the recovery → revert → confirm alert resolved.** Keep both
probers (§0.2) running.

### Tier A — one tenant, one component

#### KT-10 — Kill ONE tenant control-plane replica
```sh
POD=$($M -n kaas-capi get pod -l kamaji.clastix.io/name=tenant-a -o name | head -1)
$M -n kaas-capi delete $POD --force --grace-period=0
```
**Pass:** prober shows ≤ 3 consecutive non-200s; replacement pod `Ready` ≤ **90 s**; zero tenant
`Node` transitions; workload prober unbroken.
**Hooks:** *CP pods ready* dips 2→1→2; `TenantControlPlaneUnavailable` must **not** fire.

#### KT-11 — Sever konnectivity (server side)
Apply a `CiliumNetworkPolicy` in `kaas-capi` deny-ingress to port 8132 on the TCP pods (precise and
reversible — no pod restart).
**Expect:** `kubectl logs/exec/port-forward/top` **break within seconds**; `get/apply` keep working;
**all tenant workloads keep serving**.
**Pass:** the split is exactly as described; after deleting the CNP, `logs`/`exec` recover ≤ **60 s**.
**Hooks:** **GAP G2** — konnectivity has no health alerting today; record as unmonitorable until
`KaasKonnectivityDegraded` ships.

#### KT-12 — Kill the konnectivity agents (tenant side)
`$T -n kube-system delete pod -l k8s-app=konnectivity-agent --force --grace-period=0`
**Pass:** agents `Running` ≤ 60 s; `logs`/`exec` recover ≤ **90 s**; tenant `Node` `Ready` never
flips (if it does, kubelet liveness is coupled to the tunnel — a design finding).

#### KT-13 — Kill the kubevirt-csi controller mid-provision
Create PVC + consumer pod, then within 5 s force-delete the CSI controller pod.
**Pass:** PVC `Bound` + pod `Running` ≤ **5 min**; exactly one `volumeStatus` entry (no
duplicates/orphans); no orphaned infra PVC/`VolumeAttachment`; md5 verify succeeds.
**Hooks:** `KaasCsiControllerDown` fires only if the outage exceeds 5 m — record which happened.

#### KT-14 — Kill CDI mid-import
Force-delete the CDI deployment pod and the importer pod mid-DataVolume.
**Pass:** DataVolume `Succeeded` ≤ **10 min**; `storageprofile ceph-block` still Filesystem/RWO
after restart (the Talos Block-mode defect must not silently re-derive); no scratch PVC left.
**Hooks:** `dashboard-cdi`; **GAP G5** — no stuck-DataVolume alert exists.

#### KT-15 — Hard-kill a worker VMI (infrastructure-level crash)
`$M -n kaas-capi delete vmi <worker> --force --grace-period=0`
**Expect:** `runStrategy: Always` restarts a **fresh** VMI from the containerDisk; cloud-init re-runs
the same bootstrap; the node re-joins under the same name. This exercises the exact ground where the
**kubelet CSINode-init fatal loop** bites.
**Pass:** new VMI `Running` ≤ **2 min**; tenant `Node` `Ready` ≤ **8 min** with **zero manual
intervention**. A manual Node recreate = **FAIL** (defect KT-15-D1). Surviving-worker workloads keep
serving; dead-node pods reschedule after the 5 m unreachable toleration.
**Hooks:** `KaasWorkerVMNotReady` at 10 m; *worker VMs running* dips and recovers.

#### KT-16 — Graceful Machine delete (the control for KT-15)
`$M -n kaas-capi delete machine <worker>`
**Pass:** cordon → drain → volume detach → VM delete → replacement `Ready` ≤ **8 min**; old
`Node`/`CSINode` auto-removed; no `VirtualMachineInstanceMigration` ever created (containerDisk
workers are not migratable). **Deliverable: the KT-15 vs KT-16 delta table** — that difference is
the operational cost of ephemeral-containerdisk workers.

#### KT-17 — Worker crash WITH a hotplugged CSI volume attached
Place the KT-05 writer pod on worker-1 (hotplug volume confirmed in `volumeStatus`), then hard-kill
that VMI.
**Hypothesis to falsify:** a stale mgmt-side hotplug attachment holds the RBD image →
`Multi-Attach error`, pod stuck `ContainerCreating` forever.
**Pass:** volume reattaches and the pod runs ≤ **6 min** after the new VMI is Running, **without**
manual `virtctl removevolume`/`VolumeAttachment` surgery; **md5 unchanged**; no orphaned hotplug
volume.
**Hooks:** **GAP G4** — needs a PVC-pending alert + hotplug attached-vs-expected panel; silent today.

### Tier B — one tenant, whole cluster

#### KT-18 — Kill BOTH tenant CP replicas simultaneously
`$M -n kaas-capi delete pod -l kamaji.clastix.io/name=tenant-a --force --grace-period=0`
**Expect:** tenant API fully down for the restart window; **tenant workloads keep running**; nothing
evicts (the controller-manager is down too).
**Pass:** API outage ≤ **120 s** (prober-measured); both replicas `Ready` ≤ 150 s; workload prober
shows **zero** non-200s; no kubeadm/cert damage.
**Hooks:** `TenantControlPlaneUnavailable` fires iff the outage exceeds its 2 m `for:`; *CP pods
ready* → 0.

#### KT-19 — Tenant API LB endpoint failover
Find the node holding the `cilium-l2announce` lease for `172.18.200.1`, force-delete its Cilium
agent, watch the lease + ARP move.
**Pass:** endpoint unavailability ≤ **60 s**; lease holder changed; tenant kubectl reconnects with
no kubeconfig change; tenant nodes stay `Ready` throughout (workers reach the CP in-cluster, not via
the LB — this proves it).
**Hooks:** **GAP G1 + G3** — no series shows this outage today; needs the blackbox probe + lease panel.

#### KT-20 — MachineDeployment rollout with a broken bootstrap template
Create a copy of the KubeadmConfigTemplate poisoned with `joinConfiguration.nodeRegistration: {}`
(the documented silent-loop trap), repoint the MD at it.
**Expect:** rollout stalls; with `maxUnavailable: 0` existing workers stay `Ready`; the MachineSet
loops with the validation error visible only in capi-controller logs.
**Pass (two parts):** *Safety* — worker count never drops over 20 min. *Observability* — a stalled
rollout is detectable **from the dashboard alone within 15 min**; today it is not → this test fails
on observability until **GAP G6** (KSM CustomResourceState for CAPI CRs) ships. That is the headline
deliverable.
**Revert:** repoint the MD, delete the broken template + stuck Machine; MD back to
`readyReplicas == replicas` ≤ 10 min.

### Tier C — management-node scope (ANNOUNCE)

#### KT-21 — Management Cilium agent restart under tenant traffic
Force-delete the Cilium agent on talos-cp2 with iperf3 running VM↔VM and the workload prober live.
**Pass:** tenant traffic interruption ≤ **5 s**; **zero VMI restarts**; tenant nodes never leave
`Ready`; iperf3 dip < 10 % of the 9.89 Gbit/s baseline; agent `Ready` ≤ 60 s.

#### KT-22 — Full Cilium DaemonSet rollout
`$M -n kube-system rollout restart ds/cilium`.
**Pass:** cumulative tenant-API unavailability ≤ **30 s** across the rollout (includes one L2
handover); no VMI restart; kamaji-etcd keeps its leader throughout (an election here = the CNI
restart is disrupting the datastore — a finding).

### Tier D — platform-wide (all tenants)

#### KT-23 — kamaji-etcd: kill ONE member — ANNOUNCE
`$M -n kamaji-system delete pod kamaji-etcd-0 --force --grace-period=0`
**Pass:** tenant-API prober shows **zero** failures; `etcd_server_has_leader` never 0; member back
≤ **3 min**. **Watch WAL-fsync p99 during rejoin** — RBD-backed etcd catching up is exactly where
the PoC datastore compromise shows; `KamajiEtcdSlowFsync` firing here is signal, not noise.

#### KT-24 — kamaji-etcd: quorum loss (2 of 3) — **WINDOW**
**Purpose:** quantify the shared-datastore blast radius — the single most important number for the
per-tenant-etcd production decision.
`$M -n kamaji-system scale sts kamaji-etcd --replicas=1` (sustained quorum loss).
**Expect:** **every** tenant apiserver loses its datastore (clean write failures, stale reads);
tenant *workloads keep running* everywhere; the management cluster itself is unaffected.
**Pass:** both tenants' workload probers show **zero** interruption (the whole argument for hosted
CPs); write failures are clean errors, not hangs; after re-scaling to 3: leader ≤ **60 s**, tenant
writes ≤ **3 min**, **no manual etcd surgery**; canary ConfigMaps written pre-break survive.
**Hooks:** `KamajiEtcdNoLeader` fires ≤ 2 min and resolves ≤ 5 min post-restore.
`TenantControlPlaneUnavailable` probably does NOT fire (pods stay up) — **that is the finding**:
replica-count alerting cannot see a datastore outage → GAP **G1**.

#### KT-25 — Full management-node reboot: talos-cp2 (hosts BOTH worker VMs) — **WINDOW**
**Pre-flight:** map CP replica + etcd member placement (`-o wide`); `ceph status` HEALTH_OK. If both
tenant CP replicas are also on cp2, fix placement (topology spread) **first** — otherwise the test
conflates two faults.
**Break:** `talosctl -n 172.18.1.12 reboot` (Talos does not drain — that is part of the test).
Harder variant in the same window: `virsh destroy` + `virsh start` on compute2 (power-cut).
**Pass:** mgmt node `Ready` ≤ 6 min; Ceph `HEALTH_OK` ≤ 30 min; tenant CP stays available if
replicas were spread (record the answer); **both workers `Ready` ≤ 15 min with zero manual
intervention** → PASS; manual Node repair → CONDITIONAL (runbook exists, < 10 min) else **FAIL** and
top production blocker; CSI-volume md5 intact.
**Acceptance:** an operator reading only the KaaS dashboard must be able to say *"the tenant lost
its workers because a management node rebooted."*

---

## 3. Performance / limits (find-the-knee, brief — ANNOUNCE)

Method per `performance-testing.md` §5; all storage numbers carry the §9 SATA/nested caveat.

#### KT-26 — Hosted control-plane density
Bare TCPs in batches 5 → 10 → 20 → 40; hold 10 min each; record per-TCP CPU/RSS, kamaji-etcd WAL
fsync p99 + db size, reconcile queue, and **time-to-Ready of the next TCP** (the knee indicator).
**Knee:** next-TCP Ready > 2× baseline, or etcd fsync p99 > 100 ms sustained, or any tenant's API
p99 degrades > 20 %.
**Deliverable:** the density line for the sizing model. **Hypothesis to falsify:** the binding
constraint is shared-etcd fsync on RBD, not RAM.

#### KT-27 — Parallel provisioning time
Full clusters at concurrency 1, 2, 4, 8; 3 runs each; median + spread of time-to-Available,
decomposed by phase (TCP Ready → VMI Running → join → CNI). Any join > **4 min** is a hard failure
(kubeadm timeout), making provisioning concurrency a *correctness* limit.

#### KT-28 — kubevirt-csi attach latency + IOPS tax
fio (4k randrw QD1→64, 64k 70/30, 1M seq) on: (1) tenant PVC via kubevirt-csi hotplug, (2) the same
worker VM on a directly-attached ceph-block disk, (3) a mgmt pod on ceph-block. Attach latency:
PVC-Bound → pod-Running, 20 samples, p50/p99.
**Deliverable:** the *kubevirt-csi tax* vs (2); flag if > 20 %.

#### KT-29 — Shared-etcd noisy neighbour
`tenant-b` hammers its apiserver (kube-burner churn, 10 → 200 writes/s) while `tenant-a` measures
its own API RED at 1 Hz.
**Deliverable:** tenant-a p99 vs tenant-b write rate, with kamaji-etcd fsync p99 on the same axis.
**The knee is the fairness verdict** — and the quantified justification (or not) for per-tenant etcd.

---

## 4. Observability acceptance

A crash test is only "passed" when the failure was **visible without shell access**: an operator on
the `Talu — KaaS` dashboard + Alertmanager must localize the fault within two hops.

### 4.1 Coverage matrix

| Test | Must fire | Must show | Status |
|---|---|---|---|
| KT-10 CP replica kill | *(none — correct)* | *CP pods ready*, restarts | **covered** |
| KT-11/12 konnectivity | `KaasKonnectivityDegraded` | konnectivity health | **GAP G2** |
| KT-13 CSI controller | `KaasCsiControllerDown` | CSI replicas panel | covered |
| KT-14 CDI mid-import | `KaasDataVolumeStuck` | `dashboard-cdi` | **GAP G5** |
| KT-15/16 worker kill/delete | `KaasWorkerVMNotReady` | *worker VMs running* | covered |
| KT-17 hotplug volume | `KaasTenantPVCPending` | hotplug attached vs expected | **GAP G4** |
| KT-18 both CP replicas | `TenantControlPlaneUnavailable` | *CP pods ready* → 0 | covered |
| KT-19 LB failover | `KaasTenantApiserverDown` (blackbox) | L2 lease holder | **GAP G1 + G3** |
| KT-20 broken rollout | `KaasMachineDeploymentStalled` | MD ready/desired | **GAP G6** |
| KT-21/22 Cilium | existing cilium/node rules | Hubble flows | covered |
| KT-23 etcd member | `KamajiEtcdMemberDown`/`SlowFsync` | *has leader*, *fsync p99* | covered |
| KT-24 quorum loss | `KamajiEtcdNoLeader` + G1 | *has leader* → 0 | partly — needs G1 |
| KT-25 node reboot | node + ceph + worker rules | workers per mgmt node | needs placement panel |

### 4.2 Gaps to close

- **G1 — Tenant-API blackbox probe** ✅ **CLOSED** (`components/platform/monitoring/blackbox-exporter.yaml`
  + `kaas-probe.yaml`): a `probe-sync` reconciler (the route-sync idiom) materializes one multi-target
  `Probe` from every TCP's `.status.controlPlaneEndpoint` → `KaasTenantApiserverDown` (critical, 2 m).
  Catches the datastore/LB outages (KT-19/24) the replica-count alerts miss. Availability panel: TODO.
- **G2 — Konnectivity health**: restarts alert minimum; ideally scrape
  `konnectivity_network_proxy_server_ready_backend_connections` < worker count.
- **G3 — LB-IPAM/L2**: lease-holder panel; alert on `kaas-*` Service with empty LB ingress.
- **G4 — Tenant storage path**: `kube_persistentvolumeclaim_status_phase{namespace=~"kaas-.*",phase="Pending"} == 1 for 5m`.
- **G5 — CDI stuck imports** in `kaas-*` (> 15 m non-terminal).
- **G6 — CAPI CR state via KSM `CustomResourceState`** (copy the `ksm-velero-crs.yaml` pattern):
  Cluster/MachineDeployment/MachineSet/Machine/KubevirtMachine/KamajiControlPlane phases →
  `KaasMachineDeploymentStalled` (15 m), `KaasMachineStuckProvisioning` (10 m),
  `KaasClusterNotReady` (10 m). Makes KT-20's silent loop alertable.
- **G7 — Per-tenant RED**: tenant apiservers are deliberately unscraped from the mgmt Prometheus.
  Either scrape TCPs with Kamaji-issued client certs or accept per-tenant RED lives in the tenant's
  own stack — **record the choice** (KT-24/29 want the data).
- **G8 — `talu:kaas_*` recording rules** per `kaas-*` namespace, mirroring `talu:tenant_*`, so KaaS
  is billable through the same READ verb.

### 4.3 Observability tests

- **KT-30 — Alert-fire acceptance:** every critical alert fires within `for:` + one scrape interval
  and resolves ≤ 5 min after recovery; zero false positives during a clean KT-01.
- **KT-31 — Blind localization drill:** a second operator with only dashboard + Alertmanager names
  the broken component within 2 min for KT-13/15/18/19/24; each miss defines a missing panel.
- **KT-32 — Series-existence gate:** for every metric in `kaas-rules.yaml`/`dashboard-kaas.yaml`,
  assert `count(<series>) > 0` on live Prometheus. Run after **every** Kamaji digest change (the
  edge channel can move labels without a version bump).

---

## 4.4 Disaster recovery (tenant-cluster etcd — `components/tenancy/kaas-backup/`)

Validates that a tenant control plane is actually restorable from a `kaas-etcd-snapshot` artifact —
a Completed snapshot that cannot be restored is a lie (same discipline as the Velero restore-test).

- **KT-33 — etcd snapshot integrity + freshness:** after `phys_kaas_backup`, assert an object exists
  at `s3://kaas-etcd/<datastore>/<ts>.db`, that `etcdctl snapshot status` on the downloaded file
  reports a non-zero hash + revision, and that `KaasEtcdSnapshotStale` is **not** firing. Kill one
  etcd member and confirm the next run still succeeds (the endpoint-failover loop). **SAFE-NOW.**
- **KT-34 — Destroy-and-restore round-trip (Path A):** write a sentinel object into a tenant cluster
  (a ConfigMap), take a snapshot, **destroy the tenant's `kamaji-etcd` data**, restore from the
  snapshot (`etcdctl snapshot restore` → re-point members), and confirm the tenant API returns and the
  sentinel is present byte-for-byte. Measure RTO. **WINDOW** (destroys a tenant control plane).
- **KT-35 — PVC-data round-trip (in-tenant Velero):** with `backup.inTenant.enabled`, write a sentinel
  file into a tenant PVC, run an in-tenant Velero backup (node-agent/kopia → Garage via `garage-lb`),
  delete the workload+PVC, restore, and confirm the file returns **byte-for-byte on a new PV**. Proves
  the workload/data half that the etcd snapshot (KT-33/34) does not cover. **WINDOW.**

---

## 5. Run order, budget, and recording

| Block | Tests | Est. time | Class |
|---|---|---|---|
| Functional gate | KT-01…KT-09 | ~2 h | SAFE-NOW |
| Resilience Tier A | KT-10…KT-17 | ~3 h | SAFE-NOW |
| Resilience Tier B | KT-18…KT-20 | ~1.5 h | SAFE-NOW |
| Resilience Tier C | KT-21, KT-22 | ~45 min | ANNOUNCE |
| Resilience Tier D | KT-23 | ~30 min | ANNOUNCE |
| **Maintenance window** | **KT-24, KT-25** | **~2 h** | **WINDOW** |
| Performance | KT-26…KT-29 | ~1 day | ANNOUNCE |
| Observability | KT-30…KT-32 | folded in + 1 h | SAFE-NOW |
| Disaster recovery | KT-33 | ~30 min | SAFE-NOW |
| **Maintenance window** | **KT-34, KT-35** | **~1.5 h** | **WINDOW** |

**Per-run record:** repo git ref · `clastix/kamaji` image digest · CAPI/CAPK/provider versions ·
tenant k8s version · test id · start/end UTC · measured recovery vs budget · alerts (name, fire,
resolve) · verdict PASS/COND/FAIL · defect id.

**Graduation criterion for the KaaS layer:** all of §1, all resilience tiers at PASS or documented
CONDITIONAL, gaps G1/G2/G6 closed, and KT-29's noisy-neighbour curve on file — that curve decides
shared vs per-tenant etcd before the layer takes a second real tenant.
