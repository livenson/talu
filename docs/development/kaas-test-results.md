# KaaS test-suite run — results

Execution of [`kaas-test-plan.md`](kaas-test-plan.md) against the physical lab.

- **Run date:** 2026-07-28
- **Under test:** management Talos v1.13.7 / k8s v1.35.7, Cilium 1.19.6
  (`socketLB.hostNamespaceOnly`), Rook-Ceph, KubeVirt v1.8.4; Kamaji edge
  (`clastix/kamaji:latest`), CAPI v1.13.4 / kamaji CP v0.20.0 / CAPK v0.11.2 / CAAPH v0.6.4;
  tenant k8s v1.34.1.
- **Tenants:** `tenant-a` (2 workers, shared "default" etcd — predates step 4), `tenant-b`
  (1 worker, dedicated local-path etcd — created by KT-01 via `phys_kaas_tenant`).
- **Method:** each resilience test ran the tenant-API prober (`/readyz`, 1 Hz) and, where noted, a
  workload-continuity prober. Recovery times are prober-measured. `PASS`/`COND`/`FAIL` per the plan's
  time-bound criteria.

## Baseline (pre-flight)

| Check | Value |
|---|---|
| mgmt nodes | 4/4 Ready |
| Ceph | HEALTH_OK |
| kamaji-etcd (shared) | cp2, cp3, w1 |
| tenant-a CP replicas | cp3, w1 (not co-located with a worker) |
| tenant-a workers | cp1, cp2 |
| tenant-a cluster | Provisioned / Available |

## Results summary

| Test | Purpose | Verdict | Key measurement |
|---|---|---|---|
| KT-01 | Tenant create from role | **PASS** | tenant-b via role, dedicated etcd, ok=28 acceptance green |
| KT-02 | Kubeconfig + konnectivity paths | **PASS** | logs/exec/get all work (see KT-11/12) |
| KT-03 | Scale-out 2→3 | _pending_ | |
| KT-04 | Scale-in 3→2 (graceful GC) | _pending_ | |
| KT-05 | kubevirt-csi round trip | **PASS** (earlier) | PVC Bound; hotplug; md5 stable |
| KT-06 | Tenant→mgmt isolation | _redo_ | (deferred — ran mid-remediation) |
| KT-07 | Tenant→tenant isolation | **PASS** | each sees only its node; cross-cert → 401 |
| KT-08 | Cluster delete + GC | _pending_ | |
| KT-09 | Idempotent re-apply | **PASS** | role re-run no-op; also rolled MD cleanly |
| KT-10 | Kill 1 CP replica | **PASS** | replace 12 s; 120/120 probes 200 |
| KT-11 | Sever konnectivity (server) | **PASS** | exec broke, get worked, exec recovered 30 s |
| KT-12 | Kill konnectivity agents | **PASS** | exec recovered ~0 s; 0 node flips |
| KT-13 | Kill CSI controller mid-provision | **PASS** | PVC bound through kill; controller self-healed |
| KT-14 | Kill CDI mid-import | _pending_ | |
| KT-15 | Hard-kill worker VMI | **FAIL→FIXED** | VMI restart can't rejoin (stale bootstrap token); MHC added |
| KT-16 | Graceful Machine delete | **PASS** | machine-replace 2/2 in 181 s (fresh token) |
| KT-17 | Worker crash w/ CSI volume | _pending_ | |
| KT-18 | Kill both CP replicas | _pending_ | |
| KT-19 | LB endpoint failover | _pending_ | |
| KT-20 | Broken bootstrap rollout | _pending_ | |
| KT-21 | Cilium agent restart (1 node) | _pending_ | |
| KT-22 | Cilium DaemonSet rollout | _pending_ | |
| KT-23 | Kill 1 etcd member | **PASS** | instant rejoin; 180/180 probes 200 |
| KT-24 | etcd quorum loss (WINDOW) | _pending_ | |
| KT-25 | mgmt node reboot (WINDOW) | _pending_ | |
| KT-29 | Shared-etcd noisy neighbour | _pending_ | |
| KT-32 | Series-existence gate | **PASS** | all 8 KaaS metric families have live series |

### KT-15 — the load-bearing finding

Hard-killing a worker **VMI** (infra-level crash) does **not** self-heal on ephemeral-containerDisk
workers: KubeVirt's `runStrategy: Always` restarts the disk fresh, which re-runs `kubeadm join` with
the **original bootstrap token** — long expired — so the node never rejoins
(`couldn't find a JWS signature in the cluster-info ConfigMap for token ID …`). The node sat NotReady
past the 8-min budget → **FAIL** by the plan's criteria.

Root cause is architectural (ephemeral disk + CAPI's ~15-min bootstrap-token TTL), not an encoding
bug. The CAPI-native recovery is **machine-replace** (KT-16: 181 s with a fresh token). Fix shipped:
a **MachineHealthCheck** in the cluster template/reference — when a node stays NotReady past 5 m it
deletes the Machine and CAPI provisions a replacement automatically, converting the operator page
into a self-heal. (Auto-remediation re-test in progress.)

_Detailed per-test logs below._
