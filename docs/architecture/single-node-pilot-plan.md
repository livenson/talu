# Single-node pilot: implementation plan

Goal: the full platform — Talos, KubeVirt, Cilium, Ceph, OpenBao, Keycloak, Pomerium, Prometheus, tuppr — running on one physical machine, structured so that scaling to 3–5 nodes is a Git change plus hardware, not a rebuild.

Ordering principle: **the developer environment comes first.** It has zero hardware dependency, it bootstraps the GitOps repo every later phase consumes, and it lets Waldur plugin development start before the pilot machine is even ordered. Guiding rule throughout: make every single-node compromise explicit and reversible.

---

## Phase 1 — developer environment (first; 1–2 days, no hardware needed)

Hardware policy: **local development requires KVM.** Two ways to have it — an Apple Silicon M3/M4 Mac (macOS 15+, nested virtualization) or **any Linux machine with /dev/kvm (Ubuntu 24.04 or Rocky 9 supported), 24 GB RAM compact / 32+ GB comfortable.** The Linux path is the simpler and higher-fidelity of the two: no Lima layer (one less RAM tax, one less nesting level) and on x86 hosts the guests are amd64 — the production architecture — rather than arm64.

### Deliverable 1: the GitOps repo (created here, consumed by everything after)

```
platform-gitops/
  clusters/pilot/          # Flux Kustomizations for the pilot (Phase 4+)
  clusters/dev-local/      # overlay: dev fidelity knobs, 1 replica everywhere
  clusters/dev-shared/     # overlay: the shared remote dev cluster
  infrastructure/          # cilium, cert-manager, rook, kubevirt, cdi, ...
  platform/                # openbao, keycloak, pomerium, monitoring, tuppr
  tenants/                 # empty now; Waldur writes here later or via API
```

The rule the overlays must obey from day 1: environments differ only in **values** (emulation flag, storage class, replica counts, guest architecture, route hostnames), never in **structure**. If plugin code ever needs an "if dev" branch, the thing it branches on belongs in configuration.

**Where the repo lives:** Git hosting sits **outside the platform's failure domain**, same reasoning as Waldur and backups — the cluster must never depend on a service it hosts (a cluster that pulls its own definition from inside itself cannot be rebuilt from scratch). For the pilot: the company's existing Git hosting (GitLab/GitHub) is correct and sufficient — Flux *pulls* over HTTPS with a read-only deploy token, outbound-only, so the cluster needs no inbound exposure and the forge needs no knowledge of the cluster. If sovereignty later requires self-hosting the forge, Forgejo/GitLab goes on the management host beside Waldur — never in-cluster. CI runners (image builds, plugin tests) run on the forge's runner infrastructure or the shared dev cluster; image builds need container privileges but not KVM (libguestfs falls back to TCG for `virt-sparsify`), so ordinary runners suffice.

**Dev consumes the local checkout, not the forge.** Flux's source-controller has no `file://`, and doesn't need one:
- Inner loop (default): `make dev-sync` = `kustomize build clusters/dev-local | kubectl apply --server-side` from the working tree — uncommitted changes live in seconds; Flux installed for parity but suspended.
- Reconcile-semantics testing: `flux push artifact` of the working tree to the in-cluster zot, watched via an `OCIRepository` source — full GitOps behaviour (drift correction, prune) with no Git server.
- A throwaway local Forgejo only when webhook-driven flow is itself under test.
- Discipline: the forge stays the source of truth; CI runs from committed state only — local mode accelerates the loop, never forks reality.

### Deliverable 2: `make dev-up` / `dev-down` (host-detecting)

**Linux hosts (Ubuntu / Rocky):**
1. Prerequisites: virtualization enabled in firmware, user in the `kvm` group, `qemu-system-x86` (Ubuntu) / `qemu-kvm` (Rocky) installed. The talosctl QEMU provisioner needs root for its network setup — the make target wraps the necessary `sudo -E` invocation. On Rocky, SELinux stays enforcing; if a distro-specific denial appears, fix the label, don't disable enforcement (document the first occurrence in the repo).
2. `talosctl cluster create` with the QEMU provisioner directly on the host → 2–3 virtual Talos nodes with virtual data disks.
3. Flux → `clusters/dev-local`: real Rook Ceph, KVM-accelerated **amd64** guests, live migration, tuppr — full platform.

**macOS hosts (M3/M4):** Lima (`vmType: vz`, `nestedVirtualization: true`, Ubuntu LTS, ~40 GB RAM full / 12–14 GB compact) providing /dev/kvm, then steps 2–3 identically inside it. Guests are arm64; keep the per-architecture DataSource model so arch stays a value, not a code path.

Sizing on Linux: the compact profile (2 nodes, single-OSD Ceph at ~900 MiB target, CirrOS test guests) fits in ~10–12 GiB of host RAM — a 24 GB Linux laptop runs it alongside an IDE without ceremony; 32 GB runs the full 3-node profile.

### Dev VMs, with and without nested virtualization (both supported)

Developers working from a Linux VM rather than bare metal follow this decision tree:

1. **Can the VM get /dev/kvm?** Usually yes, one layer up: own KVM/libvirt host → `nested=1` + CPU `host-passthrough` (default-on on modern kernels); Hetzner cloud VMs expose nested KVM; GCP most families, Azure v3+; VMware/Proxmox → the "expose hardware virtualization" checkbox. AWS: metal instances only.
2. **KVM present** → the native Linux path above, unmodified, full fidelity.
3. **KVM absent** → **quick-mode-as-daily-driver**, a supported configuration: Talos-in-Docker + KubeVirt `useEmulation: true` + real Rook Ceph on loop devices or extra virtual disks (Ceph needs block devices, not KVM — storage semantics, snapshots and smart clones stay genuine). CirrOS/Alpine guests boot in ~1–2 min under TCG. Covers all plugin CRUD, identity flows, storage and CI-parity work. Not covered: performance signal and representative migration/agent timing — migration mechanically executes under TCG but is validated only on the shared cluster; the make target prints exactly this caveat on `dev-up` so nobody discovers it in a bug report.

`make dev-up` probes /dev/kvm and selects path 2 or 3 automatically; `DEV_FORCE_EMULATION=1` pins path 3 for reproducing CI behaviour locally.

**Dogfooding note:** once the pilot runs, the platform itself becomes the best source of dev VMs — a "developer workstation" flavor with CPU `host-passthrough` exposes virtualization extensions to the guest, so a tenant VM on the platform runs the full-fidelity native path. Remote dev environments become an offering the team consumes first.

### Access plane in dev — the real front door, no infrastructure

Dev must exercise the production access plane — Pomerium + Keycloak + wildcard DNS + internal CA — because auth-flow bugs (redirect URIs, cookie domains, header passing) are exactly the class that port-forward development hides until staging.

- **Hostnames: sslip.io is the documented default.** `waldur.<lb-ip>.sslip.io`-style names resolve with zero DNS setup; Pomerium route hosts and Keycloak redirect URIs are overlay values, so dev and pilot differ by one values file.
- **`make dev-trust`**: one-time import of the cert-manager dev CA into the OS/browser trust store — TLS everywhere, no warning clicks.
- **Reachability per path**: Linux native — carve the Cilium LB-IPAM pool from the talosctl QEMU bridge subnet; the host reaches Pomerium's LB IP directly. macOS/Lima — one scripted forward (socat/ssh) from Lima to the Mac for 443 on the LB IP; hostnames point at localhost. Quick mode on macOS — same forward, or accept `kubectl port-forward` for this throwaway tier.
- **VM consoles work before any ingress exists**: the VNC/serial path goes through the Kubernetes API (virt-api subresource), so Waldur's console button works the moment Waldur has a kubeconfig, on every tier; `virtctl console` / `virtctl vnc` are the zero-setup fallback.
- **Escape hatches**: `kubectl port-forward` when debugging the ingress itself; `talosctl dashboard` for the node view (needs only talosconfig).
- `make dev-up` prints the resulting URLs at the end. That printout is part of the deliverable.

### Quick mode (also what CI runs)

Talos-in-Docker + local-path — boots in ~2 min, every CRD and subresource surface genuine. On macOS this needs KubeVirt `useEmulation: true`; on Linux the Docker nodes can mount /dev/kvm, so even quick mode runs accelerated. CI on Linux runners is exactly this mode (hosted runners increasingly expose KVM, so emulation is the fallback, not the default). Same manifests, same overlay, one flag.

### Shared remote dev cluster (integration truth; can follow later)

A permanent small instance from `clusters/dev-shared` — one refurb EPYC box or 3× nested-KVM-capable Hetzner cloud VMs — reached over WireGuard, with per-developer tenants provisioned through Waldur itself. Release validation and anything multi-day-soak happens here.

### Division of labour

| Work | Environment |
|---|---|
| Everything, day to day — plugin, identity, migration logic, Ceph, tuppr | Standard local (KVM) |
| Quick API iteration, no-KVM VMs, low-RAM moments | Quick mode |
| Merge-request gating | CI = quick mode on Linux |
| Release validation, soak, performance | Shared remote |

**Consequence of doing this first:** Waldur plugin development (Phase 9) starts now, against the local environment, in parallel with everything below.

---

## Phase 2 — hardware and network (0.5 day)

**Machine** (refurb tier from the capacity planner):
- 1× EPYC 7003, 32–64 cores, 256–384 GiB DDR4
- 2× enterprise NVMe (3.84 TB, PLP) for Ceph + 1 small SSD/M.2 for Talos
- 2× 25 GbE (or 2× 10 GbE for the pilot; keep the two-port habit from day 1)
- IPMI/BMC reachable — with no SSH on Talos, the BMC console is your only out-of-band access

**Network decisions to make now, because they are annoying to change later:**
- Reserve a /28 or larger for the platform: node IP, future node IPs, a future control-plane VIP, and a small LB-IPAM pool (4–8 IPs) for Pomerium and future ingress
- DNS: `api.platform.example.com` → node IP today, VIP later; `*.apps.example.com` → LB-IPAM IP for Pomerium; `id.`, `bao.`, `admin.` similarly
- Pick pod CIDR (e.g. 10.244.0.0/16) and service CIDR sized for the *final* cluster — these are effectively immutable

**Deliverable:** rack-mounted machine, BMC verified, DNS records created, IP plan written down in the Git repo from Phase 1.

---

## Phase 3 — Talos (0.5 day)

1. Generate an Image Factory schematic. No system extensions are required for this stack (Ceph uses in-kernel RBD; KubeVirt needs only /dev/kvm, which stock Talos provides). Record the schematic ID in Git — tuppr will need it later.
2. `talosctl gen config` with patches applied from the start:
   - `machine.certSANs` and cluster endpoint = the DNS name, not the raw IP
   - `allowSchedulingOnControlPlanes: true` (single node is CP + worker)
   - `machine.features.kubernetesTalosAPIAccess` enabled for the `system-upgrade` namespace (tuppr prerequisite — cheaper to grant now than to re-apply later)
   - `machine.kubelet.extraMounts` for `/var/local-path-provisioner` (CDI scratch space)
   - explicitly leave the two data NVMes untouched by the installer (installDisk = the small SSD)
3. Apply config, bootstrap, fetch kubeconfig. Take the first etcd snapshot immediately and put the snapshot cron in place from day 1 (`talosctl etcd snapshot`, shipped off the machine).

**Verification:** node Ready; `talosctl health` clean; etcd snapshot restores in a scratch VM (actually test this once — a backup that has never been restored is a hypothesis).

**Single-node compromise:** one etcd member, no VIP. API downtime during Talos upgrades (~2–4 min). Accepted for pilot.

---

## Phase 4 — pilot bring-up: core cluster services (1 day)

The repo exists since Phase 1; this phase points Flux at `clusters/pilot` and reconciles.

Install order:
1. **Cilium** — kube-proxy replacement on, WireGuard encryption on (no-op with one node, correct with three), LB-IPAM pool + L2 announcements configured, Hubble enabled. Renovate config lands in the repo in this phase too.
2. **cert-manager** — internal CA `ClusterIssuer`; every platform service gets TLS from it.
3. **local-path-provisioner** — *only* as CDI scratch class and OpenBao/Keycloak bootstrap storage until Ceph is up. Never the default StorageClass.
4. **zot registry** — small in-cluster OCI registry (ceph-block PVC once Phase 5 lands, local-path until then), TLS from cert-manager. This is the distribution point for golden images as containerDisks and, later, a pull-through cache for platform images. Harbor replaces it only if multi-cluster replication or a tenant-facing registry becomes a requirement.

**Verification:** Flux reconciles from empty cluster to green with no manual kubectl applies; Hubble UI shows flows; a test LoadBalancer service gets an IP from the pool and answers from outside.

---

## Phase 5 — storage: Ceph in single-node mode (0.5–1 day)

The one decision that most affects scaling ease: **run Rook Ceph from day 1, even on one node**, rather than local-path — so the StorageClass, snapshot class, and CDI configuration you build everything against never change.

Single-node Ceph configuration:
- 2 OSDs (one per NVMe), 1 MON, 1 MGR
- Pool: replicated **size 2, failureDomain: osd** — disk-level redundancy on one host
- StorageClass `ceph-block` (volumeMode Block capable), VolumeSnapshotClass for smart clones
- `osd_memory_target` left at default (the planner's 5 GiB/OSD accounting applies)

**Verification:** PVC provisions; CSI snapshot + clone of a PVC completes in seconds; pull one NVMe (or down one OSD) and confirm I/O continues on the surviving replica; `ceph status` HEALTH_OK after re-add.

**Single-node compromises:** one MON (Ceph restart = brief storage pause), size 2 not 3, OSD-level not host-level failure domain. All three reverse with one Git change each at scale-out.

---

## Phase 6 — virtualization: KubeVirt + CDI + the image pipeline (1 day)

1. KubeVirt operator + CR: feature gates for hotplug and live migration on (migration is inert with one node but the API surface Waldur codes against is final). Default `evictionStrategy: LiveMigrate` in templates — on one node it degrades to shutdown-on-drain, which tuppr's single-node mode handles. Same constraint hits resize: CPU/memory hotplug executes as a live migration to *another* node, so on one node live resize degrades to reboot-resize — state it in the pilot SLA. And whenever persistent vTPM/EFI state is enabled (Windows, hardening roadmap): KubeVirt provisions a hidden `persistent-state-for-<vm>` backend-storage PVC, which **must** be on an RWX class (ceph-block) — left on an RWO default it pins the VM to its node and stalls drains and upgrades.
2. CDI with scratch class = local-path, default storage profile = ceph-block, and **DataImportCron source format = VolumeSnapshot** — golden sources stored as Ceph snapshots, so tenant clones come straight off the snapshot with no intermediate golden-PVC copy.
3. **Image pipeline** (the shape is the deliverable; contents evolve forever):
   - Golden images are defined as a Containerfile-style build in Git (bootc-shaped even if the output is a plain qcow2 for now): base cloud image + qemu-guest-agent + cloud-init + serial console + (later) bao-agent.
   - CI builds on a schedule and on base-image updates, runs `virt-sparsify` + fstrim (never ship zeros), wraps the qcow2 as a `scratch`-based containerDisk, signs with cosign, pushes to the in-cluster zot registry.
   - `DataImportCron` polls the registry every 15–30 min, imports **only on digest change**, snapshots, rolls the `ubuntu-lts` DataSource pointer forward, garbage-collects old sources.
   - Result to verify: a freshly pushed image is cluster-live within ~30 min; tenant deploy latency stays 2–5 s (smart clone) regardless — freshness and speed decoupled.

   **Golden-image content contract — bake capabilities, inject identity:**
   - Baked: cloud-init; qemu-guest-agent; bao-agent binary + unit **installed but disabled**; platform CA root; sshd `TrustedUserCAKeys` directive pointing at a cloud-init-written file; serial console; the platform APT repo source + signing key.
   - Never baked: any secret, token, per-tenant CA, tenant key, hostname, or network config — all identity arrives at first boot via cloud-init and the single-use wrapped token.
   - **In-guest auto-updates, on by default**: `unattended-upgrades` pre-configured for the security pocket + the platform repo origin, daily randomized timer, `needrestart` auto-restarting affected services, auto-reboot off (config stub present for tenants who want kernel windows).
   - **Platform APT repo** (CI deliverable alongside the image): `bao-agent` and friends packaged as signed .debs, published as static files (aptly/reprepro) behind the public route. This is how agent fixes reach *existing* long-lived VMs within a day — never via guest-exec through qemu-guest-agent, which would put the platform inside tenant guests and break the trust model.
4. Bootstrap shortcut for day one: a single manual `DataImportCron` against the upstream Ubuntu cloud-image URL is acceptable until CI exists — but the registry-based cron replaces it within this phase, not "later."
5. First VM the long way — write DataVolume + VirtualMachine by hand, boot it, `virtctl console`, snapshot it, resize its disk. Every one of these manual steps becomes a Waldur plugin function; doing them by hand once is plugin spec work, not wasted time.
6. Prove the **ephemeral flavor class** while here: boot a VM directly from the containerDisk with no PVC (writes vanish on stop) — this becomes the Waldur offering for build agents/CI runners, with near-zero provision time. Pre-pull the containerDisk on nodes (DaemonSet, or Spegel when multi-node) so "near-zero" is honest.

**Verification:** VM from clone in under 60 s; console works; disk grow online; VM survives node reboot (RunStrategy Always).

---

## Phase 7 — identity and access plane (1–1.5 days)

1. **Keycloak** (single replica, Postgres on ceph-block, DB dump cron to off-node) — realm `platform`, group naming convention `waldur/{project_uuid}/{role}` decided and documented now.
2. **OpenBao** — single replica for the pilot (Raft with 1 member), **manual unseal documented as a runbook from day 1**; audit device on; tenant-namespace layout and the SSH CA mount created; AppRole + response-wrapping bootstrap flow scripted and tested against a VM.
3. **Pomerium** — OIDC to Keycloak; routes as CRDs in Git; one protected demo route to a test VM's web port; TCP route + `pomerium-cli` tested for SSH.
4. **Cilium pinning** — the tenant-namespace `CiliumNetworkPolicy` template written and verified: from a second namespace, confirm the VM port is unreachable; through Pomerium, confirm it is.

**Verification (the security acceptance test — the pilot's exit criterion):** an unauthenticated request to the demo route bounces to Keycloak; a user in the right group passes; removing the group in Keycloak blocks within the session TTL; SSH works only via short-lived OpenBao-signed cert through the tunnel; Hubble shows the denied direct-path attempts.

---

## Phase 8 — observability and upgrades (0.5–1 day)

1. **Prometheus** (or VictoriaMetrics single binary — decide here, while retention data is small) + kube-state-metrics + KubeVirt/Ceph/Cilium ServiceMonitors. Validate the per-namespace PromQL set that Waldur billing will use, and record the queries in the repo.
2. **tuppr** — TalosUpgrade + KubernetesUpgrade CRs in Git behind Renovate with `separateMajorMinor`/`separateMinorPatch`; CEL health checks on Ceph HEALTH_OK and node readiness, **plus a gate asserting `node.status.nodeInfo.osImage` matches the upgrade target** (catches Talos's silent A/B rollback, where the upgrade RPC acks success but the node booted the old partition), **plus a post-hook alerting on lingering ContainerStatusUnknown pods** after each node cycle (known post-drain debris pattern); maintenance window Sunday 02:00 Europe/Tallinn. Execute one real Talos patch upgrade through it end-to-end — on one node this proves the single-node code path (VMs restart after reboot; measure the downtime, it becomes your pilot SLA footnote).
3. **KubeVirt upgrade gate** (separate from OS upgrades): KubeVirt/launcher version bumps can break live migration of *already-running* VMs (old-launcher → new-launcher qemu feature mismatch — seen upstream as critical at 1.6→1.7) while fresh VMs migrate fine, which would stall the next Talos rolling upgrade. Promotion rule: on dev-shared, upgrade KubeVirt, then verify a VM *created before* the upgrade still live-migrates — only then merge to pilot/prod. Keep a documented tenant-VM restart escalation for the day upstream breaks compatibility anyway.

---

## Phase 9 — tenant management: Git-first, then Waldur adoption

### 9a — phase-one management without Waldur (the pilot's operating mode)

The platform launches and serves its first tenants **before** the Waldur plugin exists. Management stack for this period:

1. **The tenant chart is the tenant API** (named deliverable): a Helm/Kustomize template producing the full namespace bundle — namespace, ResourceQuota, LimitRange, CiliumNetworkPolicy, RBAC + per-tenant ServiceAccount, OpenBao role objects — plus VM definitions from a values file. Creating a tenant or a VM = a values PR under `tenants/`, reconciled by Flux. Git history is the audit trail, merge review is the approval workflow, revert is rollback.
2. **Ownership labels from the first tenant**: every object the chart creates carries a project-UUID label (minted by hand pre-Waldur). This is what makes 9b an adoption, not a migration.
3. **CLI with real identity**: OIDC kubectl login (kubelogin) against Keycloak — group-scoped namespace RBAC, so revoking a user in Keycloak kills CLI access too. `virtctl` for VM day-2 and consoles; `talosctl`; Ceph via the Rook toolbox.
4. **Web UI without building one**: Headlamp + its KubeVirt plugin behind a Pomerium admin route (OIDC) — VM lists, lifecycle actions, in-browser consoles, authorized by the same namespace RBAC, so a technical tenant sees only their namespace. (Evaluate KubeVirt Manager as the alternative in an afternoon.) Specialist UIs — Hubble, Ceph dashboard, OpenBao UI, Prometheus — behind Pomerium routes likewise.
5. **Consciously deferred to Waldur**: self-service ordering, billing (metrics are collected, nobody invoices), quotas as product, non-Git approval flows, customer-grade dashboards.

### 9b — Waldur plugin (2–4 weeks, started in Phase 1 against dev-local, adoption-aware)

The plugin **adopts** existing Git-managed tenants by ownership label rather than recreating them — phase-one tenants enter Waldur with zero disruption, and the chart from 9a becomes the plugin's object spec.

Order of plugin capabilities:
1. Namespace bundle create/delete (namespace, ResourceQuota, LimitRange, CiliumNetworkPolicy, ServiceAccount+RBAC, OpenBao namespace + roles, Keycloak group sync)
2. VM order → DataVolume (clone from a named DataSource) + VirtualMachine; state sync from CR status; delete cascades. Offerings reference DataSource names (`ubuntu-lts`), never image versions — the pipeline owns freshness. Order attributes include **"automatic security updates" (boolean, default on, recommended)** — cloud-init enables or masks the baked unattended-upgrades timer accordingly, converting the patching stance from fine print into an explicit customer choice. Ephemeral (containerDisk) flavors carry a **recreate policy instead** — rebuilt when their DataSource rolls forward or at max-age — and the same auto-rebuild is offered opt-in for stateful flavors suited to it. BYO-image orders get the documented degraded feature matrix (no agent health, no accessCredentials, no OpenBao flow) and plugin code tolerates agent absence with timeouts, not errors — a named test case in the suite.
3. Day-2 actions: start/stop/restart, disk resize, console (virt-api VNC subresource via per-tenant SA)
4. Usage collection from the Phase 8 PromQL set → Waldur billing records; plus a **guest freshness indicator** per VM (qemu-guest-agent OS info + platform-repo access logs — no in-guest access required) surfaced on the tenant dashboard
5. Route exposure: Pomerium route CRD creation from an offering action
6. **Static internal addressing** (tiered offering feature): tier 1 — plugin-managed stable Service VIPs with user-chosen addresses from a per-tenant slice of the service CIDR (survives migration, zero new components); tier 2 — "tenant network" premium flavor: Multus bridge/VLAN secondary NIC with user-defined subnet and cloud-init static IPs (real interface IPs, migration-compatible on secondary networks). Primary-network user-defined subnets (OVN-K UDN style) remain out of scope; broad demand for them is the documented trigger to revisit the CNI decision.

Everything the plugin touches is a declarative object exercised by hand in Phases 6–7 — and available in dev-local from week one.

**Total infrastructure effort: roughly 5–7 working days** for one engineer comfortable with Kubernetes (Phase 1 included), before plugin development completes. Budget the same again for the inevitable environment-specific detours.

---

## Scaling: what actually changes at 3 and at 5 nodes

The honest headline: **scaling is easy by construction here, because nothing in the pilot is imperative.** Every difference between one node and five is a value in Git.

### 1 → 3 nodes (the qualitative jump — HA appears)

| Change | Action | Disruption |
|---|---|---|
| Control plane 1 → 3 | Generate 2 more CP machine configs, boot, they join; enable the shared VIP; repoint DNS | None; API gains HA |
| etcd 1 → 3 members | Automatic as CP nodes join | None |
| Ceph → real redundancy | Rook picks up new nodes' NVMes as OSDs; change pool `failureDomain: osd → host`, `size 2 → 3`; add 2 MONs | Online rebalance; hours of background traffic, no downtime |
| Live migration becomes real | Nothing — templates already carry LiveMigrate; first `talosctl upgrade` now migrates instead of restarting | Upgrades become zero-downtime |
| Replicated services | Bump replicas: OpenBao 1→3 (Raft join), Keycloak 1→2, Pomerium 1→2, KubeVirt mgmt 1→2; anti-affinity already in the manifests | Rolling, no downtime |
| tuppr | Remove single-node accommodations implicitly (drain now works); add parallelism/nothing | None |
| Scheduling | Remove `allowSchedulingOnControlPlanes` if moving to dedicated CP boxes | Drain of CP-hosted pods |

Elapsed effort: **1–2 days**, dominated by Ceph rebalance wall-clock and cautious verification, not by work.

### 3 → 5+ nodes (the quantitative turn — economics improve)

Add machine configs, nodes join, Rook consumes their disks, scheduler spreads — effectively zero platform work. This is where the planner's numbers move: drain reserve cost falls 33% → 20%, Ceph recovery gains headroom, and fixed ops cost spreads across more sellable GiB.

### What does *not* carry over cleanly (the honest list)

- **Pod/service CIDRs and cluster name/endpoint** — chosen in Phase 2/3, effectively permanent. This plan sizes them for the end state; do not shortcut it.
- **The pilot's uptime history** — a single-node pilot will have taken reboots; if it graduates to production node 1 of 5, wipe and rejoin it cleanly rather than carrying snowflake state (Talos makes this a 20-minute operation).
- **Local-path remnants** — anything accidentally scheduled on local-path (only CDI scratch and possibly the Phase 7 bootstrap PVCs should be) must move to ceph-block before that data matters.
- **Single-MON Ceph quirks** — MON store grew on one node; adding MONs is routine but verify quorum before the failure-domain change, not after.

### Scaling verdict

1 → 3 is a planned afternoon-to-two-days event with one background rebalance; 3 → N is essentially free. The design pays for this upfront: running Ceph and the full identity plane on one node is heavier than a minimal single-box would need — that overhead (roughly 15–20 GiB RAM and some complexity) is precisely the price of never rebuilding.

---

## Appendix — naming contract

Decided before Phase 9 encodes it; most of these names are immutable once created.

| Layer | Owner | Pattern | Example |
|---|---|---|---|
| Nodes / Talos hostnames | Platform ops | `<site>-<role><NN>` | `tll1-cp01`, `tll1-w03` |
| Platform entry points | Platform ops (Phase 2) | fixed service names + wildcard zones | `api.`, `id.`, `bao.`, `registry.`, `portal.`; `*.apps.example.com` |
| Tenant namespaces | Waldur plugin (derived) | `t-<slug>-<uuid8>` | `t-acme-erp-3f2a91bc` |
| VMs | **Tenant** (validated) | RFC 1123 label, unique per namespace | `database` |
| Derived VM objects | KubeVirt / plugin (mechanical) | `<vm>-root`, `<vm>-data-N`, `<vm>-cloudinit`, `virt-launcher-<vm>-*` | `database-root` |
| Intra-tenant discovery | Plugin (automatic) | Service per VM → `<vm>.<ns>.svc` + search domain | tenant uses bare `database` |
| External routes | Tenant leaf, platform shape | `<name>.<t-slug-uuid8>.apps.example.com` | `erp.t-acme-erp-3f2a91bc.apps.example.com` |

Rules that make it hold:

1. **Site prefix from day one**, even with one site — region in node names costs nothing now, prevents renames at multi-cluster. Decide in Phase 2 whether the apps wildcard carries region (`*.apps.tll1.…`); this is the one name customers bookmark.
2. **Names are handles, labels are truth.** Full Waldur project UUID, hardware/rack data (via Magellan), and topology live in labels; joins between Waldur and cluster state go through labels, never by parsing names.
3. **Namespace names survive Waldur project renames** — documented behaviour, not a bug. The slug is a convenience frozen at creation.
4. **The tenant's VM name is the same string everywhere**: VirtualMachine object, guest hostname (cloud-init), console title, DNS name, invoice line. No generated IDs in tenant-visible places.
5. **Primary pod IPs are ephemeral; stability is layered above them** — the per-VM Service tracks live migration, so the default tenant contract is "reach your VMs by name"; tenants needing fixed addresses get user-chosen stable Service VIPs (tier 1) or static IPs on a secondary NIC (tier 2). Cloud-init sets the namespace as DNS search domain so bare names work.
6. **One identity vocabulary across audit logs**: Keycloak username = SSH certificate principal = Pomerium session subject, so Pomerium, OpenBao, and sshd logs correlate without mapping tables.
7. Reserved prefixes: `t-` is tenant-only; platform namespaces never use it; VM names may not shadow platform service names within the search domain (validated at order time).
