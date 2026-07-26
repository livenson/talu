# Performance testing & capacity engineering for Talu

How to measure a Talu deployment end-to-end, find where the infrastructure gives out, and push the
operating point as far as it will go **without breaking the tenant SLO or the failure domain**. The
goal is not a benchmark leaderboard — it is a defensible answer to two questions:

1. **How much can one node/cluster actually carry?** (density: VMs, IOPS, Gbit/s, req/s per rack-unit)
2. **Where is the next bottleneck, and is removing it worth it?** (so tuning effort goes where it pays)

> "Smart" squeezing = maximising *useful work ÷ resources consumed* while keeping the 99th-percentile
> latency and the N-1 host-failure headroom inside contract. Raw peak throughput at p99 = 3 s is not
> a win for a VM platform.

---

## 1. Principles

- **Measure a ceiling, a floor, and a knee.** For every resource: the theoretical max (hardware spec),
  the idle overhead Talu itself consumes (Cilium, Ceph, kubelet, virt-handler), and the *knee* — the
  load at which latency starts climbing super-linearly. The operating point sits just below the knee,
  with headroom for one host failure.
- **One variable at a time.** Change the CPU model, or the MTU, or the OSD count — never three. Keep a
  pinned baseline config in git; every result references the config hash.
- **USE for resources, RED for services.** Resources (CPU, disk, NIC, OSD): **U**tilisation,
  **S**aturation (queue depth), **E**rrors. Services (API, VM console, tenant app): **R**ate,
  **E**rrors, **D**uration (latency percentiles). Saturation is the leading indicator; utilisation
  alone lies (a 60 %-utilised disk with a 200-deep queue is already failing).
- **Efficiency ratio is the headline number.** `achieved ÷ theoretical` per layer. A node doing
  400 k IOPS against NVMe rated for 1 M is 40 % efficient — that gap is the tuning budget.
- **Steady-state *and* storms.** Averages hide the failure modes. Test boot storms (100 VMs at once),
  migration storms (drain a host), snapshot storms (backup window), and the noisy-neighbour case.
- **The lab caveat is load-bearing.** The nested `rocky-sandbox` lab (Talos-in-Podman, `useEmulation`,
  loop/qcow2 OSDs) proves *correctness only* — its numbers are meaningless. All perf work runs on
  KVM-capable hardware (`environments/<site>` with real `/dev/kvm`, real disks). See §9.

---

## 2. The stack under test

Talu is a layered system; a bottleneck at any layer caps everything above it. Test bottom-up so each
layer's ceiling is known before the next is loaded.

```
  tenant workload (the app in the VM)                     ← what the customer feels
  ─────────────────────────────────────
  KubeVirt VM        (virtio, vCPU, guest mem, live-migrate)
  Kubernetes         (API, etcd, scheduler, density)
  Cilium dataplane   (eBPF, VXLAN/native, LB-IPAM, policy, encryption)
  Rook-Ceph          (RBD IOPS/BW/latency, replication, recovery)
  Talos + KVM host   (CPU/SMT/NUMA, memory/hugepages/KSM, qemu overhead)
  hardware           (cores, RAM, NIC, disks, PCIe/IOMMU)
```

---

## 3. Per-layer test plan

Each layer: **baseline → saturate → find knee → apply levers (§4) → re-measure → record efficiency.**

### 3.1 Host / KVM
- **CPU:** `stress-ng --cpu`, `sysbench cpu`, `coremark` inside a pinned VM vs on bare metal → the
  *virtualisation tax* (target <3–5 % with `dedicatedCPUPlacement`). SMT on/off. NUMA-local vs
  NUMA-crossing (pin a VM's vCPUs + memory to one socket vs split) — cross-node memory is the silent
  killer on 2-socket boxes.
- **Memory:** `stream` (bandwidth), latency (`lat_mem_rd`). Measure KSM merge ratio and its CPU cost;
  measure overcommit behaviour (ballooning, swap pressure) at 1.2×, 1.5×, 2× RAM.
- **Exit:** virtualisation tax quantified; NUMA penalty quantified; the point where overcommit starts
  paging is known.

### 3.2 Storage (Rook-Ceph RBD)
- **Tool:** `fio` with the KubeVirt-realistic profiles: 4k randread/randwrite (QD1 → QD64), 64k mixed
  70/30, 1M seq. Run *inside a VM on an RBD disk*, not just on the host — the virtio-blk path is part
  of the number.
- **Dimensions:** replica size (2 vs 3), failure domain (host vs osd), OSDs-per-device,
  BlueStore cache size, RBD client cache, `rbd_read_from_replica_policy`. Single-VM latency **and**
  aggregate cluster IOPS with 1→N concurrent VMs (find the point where per-VM latency degrades).
- **Recovery test (the one everyone skips):** kill an OSD/host under load and measure the client
  latency spike + rebuild time. A cluster that does 500 k IOPS but stalls tenants for 40 s during a
  disk replacement is mis-tuned.
- **Exit:** per-VM p99 latency curve vs cluster load; the concurrent-VM count at the knee; rebuild
  impact bounded.

### 3.3 Network (Cilium)
- **Tools:** `iperf3`/`netperf` (TCP + UDP, single- and multi-stream), `sockperf`/`netperf TCP_RR`
  for latency, `qperf`. Test each path: pod↔pod same-node, pod↔pod cross-node (VXLAN vs native
  routing), VM↔VM cross-host, north-south through LB-IPAM, and through the Pomerium ingress.
- **Dimensions:** MTU (1500 vs jumbo 9000 — huge for throughput), `routingMode` tunnel vs native,
  `bpf.masquerade`, WireGuard encryption on/off (measure the tax), L3/L4 vs L7 CiliumNetworkPolicy
  cost, kube-proxy-replacement vs iptables. Bond mode / LACP hashing under multi-flow.
- **Exit:** line-rate (or the fraction achieved) per path; encryption + policy tax quantified; MTU
  decision validated by numbers.

### 3.4 KubeVirt VMs
- **Boot time:** cold boot, and **boot storm** (50–100 VMs scheduled at once) — surfaces image-pull,
  CDI-clone, and RBD-provision contention. The registry mirror (`phys_registry_mirror`) and
  DataImportCron snapshot strategy live or die here.
- **Live migration:** time to migrate an idle VM, a memory-dirtying VM (`stress-ng --vm`), and a
  storage-busy VM; measure the *guest-visible* pause (should be sub-second) and the migration's
  effect on co-tenants. Migration bandwidth vs the network layer's ceiling.
- **Density:** VMs-per-node at fixed vCPU:pCPU overcommit ratios (1:1, 2:1, 4:1) until guest steal%
  or p99 app latency breaches SLO. This is the money metric.
- **Exit:** boot-storm completion curve; migration pause + co-tenant impact; the density/overcommit
  table with the SLO breach line marked.

### 3.5 Kubernetes control plane
- **Tool:** `kube-burner` (or `clusterloader2`) — create/delete N VMs/tenants, measure API p99,
  etcd fsync/commit latency, scheduler throughput, pod/VMI ready-time. Talos etcd on the OSD-shared
  disk vs a dedicated disk is a real variable here.
- **Exit:** VMI-creation rate the control plane sustains; etcd headroom; the API latency knee.

### 3.6 End-to-end tenant
- A representative tenant profile (e.g. web+db VM pair, or a batch fleet) driven by `k6`/`vegeta`/
  `wrk`, while other tenants generate noise. Confirms the whole stack holds the SLO under
  multi-tenant contention — the thing unit-layer tests can't show.

---

## 4. The "smart squeezing" levers

Where the density/throughput actually comes from, per layer. Apply, then re-measure §3 — never assume.

| Layer | Lever | Payoff | Cost / guard-rail |
|---|---|---|---|
| CPU | `dedicatedCPUPlacement` + NUMA topology + `isolCPUs` for latency-sensitive VMs | near-bare-metal, low jitter | fragments the node; reserve host cores |
| CPU | vCPU:pCPU **overcommit** (2:1–4:1) for bursty tenants | 2–4× density | steal% + p99 SLO is the ceiling |
| Memory | **KSM** (dedup identical guest pages) | 10–40 % on homogeneous fleets | CPU cost; off for latency-critical |
| Memory | hugepages (2M/1G) for guest RAM + DBs | TLB wins, less overhead | pre-allocated, non-swappable |
| Memory | overcommit + balloon + fast swap (NVMe) | density on idle-heavy fleets | page-in latency; bound the ratio |
| Storage | replica 2 + host failure domain (vs 3) on trusted HW | +50 % usable, less write amp | durability trade — decide per tier |
| Storage | RBD cache, `imageFeatures` (fast-diff, object-map) | faster clones/snaps, less read | memory per client |
| Storage | one OSD per fast NVMe, DB/WAL sizing, `bluestore` tuning | closes the achieved-vs-rated gap | rebuild time |
| Network | **jumbo MTU 9000** end-to-end | large-transfer throughput ↑↑ | must be consistent on every hop |
| Network | native routing (vs VXLAN) where the fabric can route PodCIDRs | drops encap overhead + MTU cost | needs BGP/routed fabric |
| Network | SR-IOV / VFIO passthrough for NIC-bound VMs | line-rate, low CPU | breaks live-migration; IOMMU |
| Network | XDP acceleration, eBPF host-routing | lower latency, higher pps | NIC/driver support |
| Scheduling | descheduler + live-migration rebalancing | bin-pack, reclaim stranded capacity | migration cost |
| Scheduling | topology/affinity so replicas + noisy tenants spread | protects tail latency | less bin-packing |
| Platform | registry mirror + CDI snapshot DataSources | kills boot-storm egress + clone time | cache disk |

**The oversubscription discipline:** density comes mostly from overcommit (CPU, memory, and thin
storage). The art is finding the ratio where *statistical* peak demand (not sum-of-peaks) still fits,
using measured per-tenant duty cycles — then leaving N-1 headroom so a host failure's evacuated VMs
land without cascading. Oversubscribe the *average*, provision for the *correlated peak*.

---

## 5. Methodology / workflow

```
for each layer bottom-up:
  1. pin baseline config (git ref)         # reproducible
  2. measure floor  (idle overhead)        # what Talu costs before any tenant
  3. measure ceiling (single-stream max)   # best case
  4. ramp load → find the knee             # U/S/E + latency percentiles
  5. apply ONE lever (§4)                  # hypothesis-driven
  6. re-measure 3–4 → Δ + new efficiency   # did it pay?
  7. record: config hash, result, verdict  # so it's not re-litigated
```

- **Warm up, run long, repeat.** Discard the first minute; run ≥10 min steady-state; ≥3 runs, report
  median + spread. Ceph and page caches lie for the first few minutes.
- **Close the loop with prod telemetry.** The tuned operating point is a hypothesis until real tenant
  load confirms it. Feed production percentiles back into the model.

---

## 6. Metrics, tooling, observability

Talu already ships the observability plane — reuse it, don't bolt on a parallel one:

- **Prometheus + Perses** (`components/platform/monitoring/`) with node-exporter, cAdvisor,
  **Ceph mgr exporter**, **Cilium/Hubble metrics**, **KubeVirt/virt- metrics**, kube-state-metrics,
  etcd metrics. Add `fio`/`iperf` result push (pushgateway) so runs land on the same dashboards.
- **The four golden signals per layer:** latency (p50/p95/p99/p99.9 — *always percentiles, never
  averages*), traffic, errors, saturation.
- **Guest-internal truth:** `steal%` (CPU contention the host hides), guest disk await, guest retransmits.
  A host that looks 70 % utilised while guests see 20 % steal is oversubscribed past the knee.
- **Flamegraphs / `perf` / eBPF** (`bpftrace`) on the host when a layer underperforms its ceiling —
  find *where* the cycles go before tuning blind.

---

## 7. Capacity / sizing model (the deliverable)

The point of all this is a model that predicts, not just describes:

```
VMs_per_node  = min(
  usable_pCPU  × cpu_overcommit  / vCPU_per_VM,
  usable_RAM   × (1 + ksm_ratio) / (1 - overcommit_slack) / RAM_per_VM,
  cluster_IOPS_at_knee           / IOPS_per_VM,
  NIC_Gbit_at_knee               / Gbit_per_VM
) × (1 - n_minus_1_headroom)
```

The binding constraint (the `min`) is the bottleneck to spend tuning budget on; the others have slack.
Re-solve per tenant profile (batch vs latency-sensitive vs storage-heavy) — one number per class.

---

## 8. Phased plan (with exit criteria)

| Phase | Focus | Exit criterion |
|---|---|---|
| P0 | Rig + baselines: pin config, wire result-push to Perses, floor/ceiling per layer | every layer has a floor+ceiling on a dashboard |
| P1 | Storage: `fio` matrix, concurrent-VM knee, recovery-under-load | per-VM p99 curve + safe concurrent-VM count |
| P2 | Network: path matrix, MTU/encryption/policy tax | line-rate fraction per path; MTU decision by number |
| P3 | Compute: virt-tax, NUMA, overcommit/KSM density table | density table with the SLO-breach line |
| P4 | KubeVirt ops: boot storm, live-migration storm | storm curves + guest-visible pause bounded |
| P5 | Control plane: `kube-burner` density | sustained VMI-create rate; etcd headroom |
| P6 | E2E multi-tenant + noisy-neighbour under SLO | SLO held at target density with contention |
| P7 | Model + operating point + N-1 validation | sizing model published; host-failure drill passes |

---

## 9. This hardware / lab-specific notes

Right-sizing the *method* to the current physical lab (`environments/rocky-phys`, 4× Quanta T41S-2U,
2×Xeon E5-2673 v4, 2×10 G LACP bond @ MTU 9000, SATA SSD):

- **The SATA SSD is the storage bottleneck, by far.** OSDs on a single SATA SSD (shared with the OS)
  will cap IOPS far below the network or CPU. Perf-*correctness* (RBD semantics, replication behaviour,
  recovery) is valid here; absolute IOPS numbers are not representative — flag every storage result as
  "SATA-bound, not production-representative". Real numbers need NVMe.
- **Boot the non-`+debug` kernel** before any measurement (`phys_host_prep` stages this) — the debug
  kernel's lock/alloc instrumentation invalidates every latency figure.
- **Nested vs bare metal:** the current cluster runs Talos as *libvirt VMs* (reversible). Nested KVM
  adds a tax; treat these as *relative* comparisons and a method dry-run. Absolute ceilings need
  bare-metal Talos on the same boxes (a values change, not a rebuild).
- **NUMA matters here** (2 sockets): pin VMs and OSDs to sockets and measure the cross-node penalty —
  it's one of the biggest free wins on this class of hardware.
- **Network: the pod-to-pod ceiling is ~3.2 Gbit/s, NOT the 10 G bond — measured, and it's a NIC
  limitation, not a config.** Raw host-to-host over the bond hits **9.9 Gbit/s** (4 streams, healthy),
  but pod-to-pod across nodes caps at **~3.2 Gbit/s** with the host **98 % idle**. Root cause: the
  hosts' **Intel 82599 (ixgbe)** cannot GRO-aggregate VXLAN-encapsulated traffic — a documented
  82599-specific limitation that pins VXLAN throughput at ~3 Gbps
  ([kernel patch](https://patchwork.ozlabs.org/patch/488586/), [Red Hat](https://access.redhat.com/solutions/2780711)).
  It is NOT movable from userspace — verified: identical ~3.2 Gbit/s under Cilium tunnel vs **native
  routing**, single-queue vs **virtio multiqueue** (8 queues confirmed active), and with the tunnel/GRO
  offloads on vs off. The fixes are all substrate-level: **remove the host VXLAN** (routed provider
  VLAN or an L3 host fabric), **newer NICs** (X710/ConnectX with working VXLAN GRO), or **bare metal**
  (Phase 2 — no host VXLAN at all). So on this lab, treat pod-network throughput as a fixed ~3.2 Gbit/s
  overlay ceiling; the bond/LACP itself is fine (validate multi-leg hashing on the raw path, not the
  overlay). compute4's bond runs a single leg (degraded-hardware data point).
- **Cilium routing mode:** switched to **native** here (`routingMode: native` + `autoDirectNodeRoutes`)
  to drop the Cilium-VXLAN-in-host-VXLAN double encap. Correct architecturally (+MTU, less CPU) but it
  does NOT raise throughput on this lab — the 82599/VXLAN ceiling above dominates. The win is real only
  once the host VXLAN is gone (bare metal / routed fabric).
- **Enable IOMMU** (`phys_host_prep` stages `intel_iommu=on`) if SR-IOV passthrough is on the roadmap;
  the NICs expose 63 VFs/port.

---

## 10. Anti-patterns (don't ship these numbers)

- Averages instead of percentiles; a single run; a 30-second run.
- Testing on the nested/emulated lab and quoting the numbers as capacity.
- Utilisation without saturation (a "50 % busy" disk with a 100-deep queue is saturated).
- Peak throughput without the corresponding p99 latency.
- Sum-of-peaks capacity planning (guarantees massive over-provisioning); use measured duty cycles.
- Tuning the non-binding constraint (polishing CPU when storage is the `min`).
- Forgetting N-1: a cluster packed to 100 % has nowhere to evacuate a failed host's VMs.
