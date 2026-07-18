# Talu — platform context

> Purpose of this file: working context for AI-assisted development (Claude Code) on the Talu platform. It states what the system is, every architectural decision already made with its rationale, the conventions code must follow, and where to look things up. Treat decisions here as settled unless the task explicitly reopens them.

## What Talu is

Talu (Estonian: farmstead — "own your ground") is a sovereign, multitenant VM platform: fast tenant environment provisioning, HA, zero-downtime updates, with a deliberately small operational footprint. **API-first by construction**: the complete management surface is the Kubernetes declarative API (all tenant/VM/route/policy state as labelled, watchable objects) plus the Prometheus HTTP API (per-tenant usage). Talu is designed for integration with external billing and management platforms — Waldur is the reference integration, not a hard dependency; any manager that writes objects and reads metrics can drive the platform, and phase one runs Git-first with no manager at all. Kubernetes/KubeVirt substrate underneath. Target buyers: European organisations wanting VMs on owned or dedicated hardware — sovereign clouds, HPC-adjacent centres, compliance-sensitive SMEs.

Positioning: sell dedicated-performance 8–64 GiB flavors priced ~Hetzner-CCX-minus-10-20%; never compete with budget shared tiny VMs. Differentiators: data locality, real multitenancy (org/project), no egress fees, included storage, identity-aware access everywhere, EU supply chain.

## Stack, one line per layer

| Layer | Technology | Single responsibility |
|---|---|---|
| OS | Talos Linux (immutable, API-managed, no SSH) | nodes, KVM, atomic A/B upgrades |
| Orchestration | Kubernetes (3 CP nodes, Talos-managed, VIP) | declarative state + scheduling; the ONLY API Waldur talks to |
| Virtualization | KubeVirt + CDI | VM lifecycle, live migration, image import/clone |
| Network | Cilium (kube-proxy replacement, WireGuard node encryption, LB-IPAM + L2, Hubble) | eBPF datapath, tenant isolation, external IPs, flow logs |
| Storage | Rook Ceph, RBD, volumeMode Block, RWX | disks, snapshots, smart clones; RWX is what makes live migration work |
| Secrets | OpenBao ×3 (Raft), per-tenant namespaces, SSH CA | tenant secrets, short-lived SSH certs; unseal material stored off-cluster |
| Identity | Keycloak (single OIDC IdP) | one identity for Waldur, Pomerium, OpenBao, kubectl; one revocation point |
| Access | Pomerium (IAP = the ingress; no separate ingress controller) | policy door for all inbound sessions — per route, from fully public to group-gated; SNI fan-out on one IP :443 |
| Metrics | Prometheus (or VictoriaMetrics — open decision at Phase 8) | per-namespace usage → Waldur billing; no Grafana, Waldur renders charts |
| Upgrades | tuppr + Renovate + Flux | Git-merge-triggered, health-gated (CEL: Ceph HEALTH_OK, no running VMIMs), maintenance windows |
| GitOps | Flux, repo on external forge (pull-only, deploy token) | cluster state = Git; audit trail = commit history |
| TLS | cert-manager, internal CA | everything internal; CA root baked into golden images |
| Registry | zot (in-cluster) | golden images as containerDisks; pull-through cache |
| Tenancy/billing | Waldur (external host, outside failure domain) | orders, roles, quotas-as-product, billing, charts, console proxy |

## Non-negotiable design rules

1. **Declarative only — and manager-agnostic.** External platforms (Waldur or any other) manage Talu exclusively through Kubernetes objects and Prometheus queries. No proprietary control API, no imperative side channels. Integration-relevant consequences: ownership labels are the join key for any external system; object status is the only progress signal; nothing in the platform may assume Waldur specifically.
2. **Values, not structure.** Environments (dev-local, dev-shared, pilot, prod) differ only in overlay values. `if dev` branches in code are bugs; the condition belongs in configuration.
3. **Bake capabilities, inject identity.** Golden images contain mechanisms (agents, CA roots, sshd hooks — installed, disabled); cloud-init injects everything per-tenant/per-VM at first boot via single-use wrapped OpenBao tokens. Nothing secret is ever in an image or etcd-resident cloud-init.
4. **The platform never acts inside tenant guests.** No guest-exec via qemu-guest-agent for management. Agent updates reach guests via the platform APT repo + unattended-upgrades (tenant-controllable, default on).
5. **Names are handles, labels are truth.** Joins between Waldur and cluster state go through labels (project UUID label on every tenant object), never by parsing names.
6. **Primary pod IPs are ephemeral by design; stability is a layered promise.** The masquerade binding swaps the pod IP on live migration — never promise its stability. Stable addressing is delivered above it: DNS names (per-VM Service + namespace search domain, the default contract), user-chosen stable Service VIPs (tier 1), and static IPs on a tier-2 secondary NIC where tenants need fixed interface addresses.
7. **One policy-controlled front door, per-route openness.** All inbound web and tunneled-session traffic enters via Pomerium; each route sets its own policy — from `allow: public` (anonymous websites, the APT repo) to group-gated admin surfaces. Cilium pins the tenant path to the proxy in eBPF (non-bypassable). Service-to-service traffic never traverses the IAP; tenant-hosted raw TCP/UDP services use dedicated LB IPs that deliberately bypass it, with their own generated Cilium ingress policy.
8. **Out-of-cluster survival kit** (the only things the cluster cannot rebuild itself from): Git forge, Waldur host, etcd snapshots, Keycloak DB dumps, OpenBao unseal material. Everything else is rebuildable.
9. **One identity vocabulary**: Keycloak username = Pomerium session subject = SSH cert principal, across all audit logs.
10. Ceph pools/StorageClass exist from day one even on one node (size 2, failureDomain osd) so scaling is a values change, never a storage migration.

## Naming contract

- Nodes: `<site>-<role><NN>` → `tll1-cp01`, `tll1-w03`
- Tenant namespaces: `t-<slug>-<uuid8>` → `t-acme-erp-3f2a91bc` (slug frozen at creation; survives Waldur renames)
- VMs: tenant-chosen RFC 1123 label; same string as guest hostname, DNS name, console title, invoice line
- Derived: `<vm>-root`, `<vm>-data-N`, `<vm>-cloudinit`
- Discovery: `<vm>.<ns>.svc` + search domain → tenants use bare names
- External: `<name>.<t-slug-uuid8>.apps.example.com`; entry points `api. id. bao. registry. portal.`
- Reserved: `t-` prefix is tenant-only; VM names may not shadow platform service names

## Tenant model

Waldur project → namespace bundle (one Helm/Kustomize chart, also the pre-Waldur tenant API):
namespace + ResourceQuota + LimitRange + CiliumNetworkPolicy (default: intra-namespace allowed, cross-namespace denied, ingress only from Pomerium) + RBAC + per-tenant ServiceAccount (console access) + OpenBao namespace/roles + Keycloak groups `waldur/{project_uuid}/{admin|member}`.
VM order → DataVolume (smart clone from named DataSource, e.g. `ubuntu-lts`) + VirtualMachine. Deploy path: order → clone 2–5 s → boot → cloud-init ≈ 15–40 s total.
Flavor classes: standard (memory overcommit ≤1.2, CPU 4:1); premium (no mem overcommit, dedicated CPU placement); ephemeral (containerDisk, no PVC, recreate-on-image-roll policy).
**User-configurable internal IPs (requirement)**: tier 1 = stable Service IPs with user-chosen addresses, implemented natively via Cilium LB-IPAM — a per-tenant `CiliumLoadBalancerIPPool` (namespace-selected, internal non-announced range) + the `lbipam.cilium.io/ips` annotation on the VM's Service; Cilium validates pool membership, so the plugin does no IPAM bookkeeping. The sharing-key annotation additionally allows one IP across several services/ports. Tier 2 = Multus bridge/VLAN secondary NIC "tenant network" flavor with user-defined subnets via cloud-init. Cilium has no per-pod static-IP mechanism (long-standing declined requests #17026/#23005 — conflicts with its IPCache identity model); primary-network UDN-style subnets/persistent pod IPs are an OVN-Kubernetes capability and remain out of scope — broad demand triggers CNI reconsideration. The DNS-not-IPs default contract stays for everything else.
**IdP swap-ability**: Keycloak is the default (ecosystem, EuroHPC/MyAccessID familiarity, Waldur-proven), but all consumers speak generic OIDC — keep the Waldur→IdP group-sync behind an interface so authentik (or Kanidm/ZITADEL) remains a values-level substitution, not a rewrite.

## Image pipeline

Containerfile-shaped build in Git → CI (virt-sparsify, cosign sign) → containerDisk in zot → DataImportCron (digest-change only) → VolumeSnapshot source → DataSource pointer rolls → tenant clones always hit latest. Freshness and deploy speed are decoupled. Golden image contents per rule 3. Platform APT repo ships bao-agent updates to running guests.

## Capacity model (from the planner)

Per-node overhead ≈ 3.3 GiB base + 5 GiB/OSD + services; sellable = (RAM − overhead) × (1 − margin 10%) × (N−1)/N drain reserve; per-VM launcher overhead 0.25 GiB. Drain reserve is purchased capability (zero-downtime upgrades), not padding. Plan RAM ≤ (N−1)/N of sellable. 2 NICs minimum: Ceph replication separate from pod/migration traffic. Reference build: 5× refurb EPYC 7003, 384–512 GiB DDR4, 2× NVMe (PLP), 2×25 GbE + 3 small CP nodes. DRAM/NAND crisis (2026) makes refurb DDR4 the rational tier.

## Environments

- **dev-local** (Phase 1, no hardware): KVM required — Linux native (Ubuntu 24.04/Rocky 9, talosctl QEMU provisioner, amd64 guests, best fidelity) or macOS M3/M4 via Lima nested virt (arm64 guests). Compact profile: 2 nodes, 1 OSD @ ~900 MiB target, CirrOS/Alpine guests → ~10–12 GiB host RAM. No-KVM fallback: Talos-in-Docker + KubeVirt useEmulation (real Ceph on loop devices; migration not representative). `make dev-up` probes and selects; `DEV_FORCE_EMULATION=1` pins emulation.
- Dev sync: `make dev-sync` applies working tree (Flux suspended); `flux push artifact` → zot OCIRepository for reconcile testing; forge remains truth; CI runs committed state only.
- Dev access plane is the real one: Pomerium + Keycloak + sslip.io hostnames + `make dev-trust` (import dev CA). Consoles work via K8s API before any ingress (virtctl / Waldur proxy).
- **dev-shared**: 1 refurb box or 3× Hetzner cloud VMs (nested KVM); release validation, soak.
- **pilot**: 1 physical node, all single-node compromises documented and reversible (1 etcd, 1 MON, size-2 osd-domain pools, single-replica services).

## Sequence (plan phases)

1 dev env + GitOps repo → 2 hardware/network (IP plan, CIDRs — permanent!) → 3 Talos → 4 Flux + Cilium/cert-manager/local-path/zot → 5 Rook Ceph → 6 KubeVirt/CDI + image pipeline → 7 Keycloak/OpenBao/Pomerium + Cilium pinning (security acceptance test = exit criterion) → 8 metrics + tuppr → 9a Git-managed tenants (tenant chart, Headlamp UI, OIDC kubectl) → 9b Waldur plugin (adopts by label). Scaling 1→3 = 1–2 days (CP join, pool size 2→3 host-domain, replicas up, migration goes live); 3→N ≈ free.

## Deliberately rejected (do not reintroduce without cause)

Standalone Rust orchestrator (Orca-style) — undifferentiated infra; Cloud Hypervisor/Firecracker standalone — KubeVirt won on live migration + ecosystem; Incus — lost on GPU/ecosystem trajectory; OpenStack — a strong fit for broader IaaS scenarios than Talu targets, so not adopted for this scope (Waldur's OpenStack integration remains a separate, supported product line); Cilium replaced nothing→ actually replaced: ingress controller, MetalLB, VPN mesh; Grafana — Waldur renders PromQL; kured — Talos-native upgrades + tuppr; ESO — direct bao-agent; guest-exec management — trust model; separate DNS/DHCP for VMs — cloud-init static + CoreDNS.

## Open decisions (flagged, not settled)

Prometheus vs VictoriaMetrics (Phase 8, retention/billing driven); region label in apps wildcard (`*.apps.tll1.…`) — decide Phase 2; Harbor if multi-cluster replication needed; vTPM-backed cert auth replacing AppRole bootstrap (hardening, later); name Talu vs Waldur-family branding (trademark diligence pending); **Cilium multi-pool IPAM for per-tenant pod CIDRs** (makes each tenant's VMs occupy a known range so external firewalls can reason about tenants — not per-VM pinning) — attractive but IPAM mode cannot be changed on a live cluster, so this must be decided at Phase 2 bootstrap or foregone until a cluster rebuild.

## Field notes from Cozystack's tracker (known landmines in shared components)

Cozystack runs 80% of this stack in production; their issues transfer. Treat these as constraints:
- **vTPM/EFI persistence**: KubeVirt creates a hidden `persistent-state-for-<vm>` PVC; on an RWO class it pins the VM, blocking live migration and stalling drains/upgrades. If persisted state is enabled, force RWX ceph-block.
- **KubeVirt version bumps can strand running VMs**: old-launcher → new-launcher migration compatibility has broken upstream (1.6→1.7, qemu feature flags). Gate KubeVirt promotions on "pre-upgrade VM still migrates" (dev-shared).
- **Talos silent A/B rollback**: upgrade RPC can ack success while the node rebooted the old partition. tuppr CEL gate checks `nodeInfo.osImage` against target.
- **Post-drain debris**: lingering ContainerStatusUnknown pods after node cycles; post-hook alerts on them.
- **CPU/memory hotplug executes as live migration to another node** — impossible on single-node; resize = reboot there.
- Their LINSTOR/DRBD pain (DKMS + Secure Boot, LVM/multipathd grabbing volumes, quorum fencing storms) and Kube-OVN pain do NOT transfer — they are why Talu chose Ceph-on-Talos and Cilium-only.

## Lookup links

Core platform:
- Talos: https://www.talos.dev/latest/ (machine config reference, QEMU/Docker provisioners under "advanced")
- Talos Image Factory: https://factory.talos.dev/
- KubeVirt user guide: https://kubevirt.io/user-guide/ (VM API, migration, instancetypes, accessCredentials)
- KubeVirt API reference: https://kubevirt.io/api-reference/
- CDI: https://github.com/kubevirt/containerized-data-importer (DataVolume/DataImportCron docs in /doc)
- Cilium: https://docs.cilium.io/ (LB-IPAM, L2 announcements, CiliumNetworkPolicy, WireGuard, Hubble)
- Rook: https://rook.io/docs/rook/latest/ ; Ceph: https://docs.ceph.com/
- Flux: https://fluxcd.io/flux/ (GitRepository/OCIRepository sources, image automation)
- tuppr: https://github.com/home-operations/tuppr
- Renovate: https://docs.renovatebot.com/

Identity & access:
- Pomerium: https://www.pomerium.com/docs (routes, policy, TCP tunneling, ingress controller)
- Keycloak: https://www.keycloak.org/documentation (admin API for group sync)
- OpenBao: https://openbao.org/docs/ (namespaces, AppRole, response wrapping, SSH secrets engine)
- kubelogin (OIDC kubectl): https://github.com/int128/kubelogin
- cert-manager: https://cert-manager.io/docs/

Supporting:
- zot registry: https://zotregistry.dev/
- Headlamp + KubeVirt plugin: https://headlamp.dev/ , https://github.com/kubevirt/headlamp-plugin
- Waldur docs: https://docs.waldur.com/ ; source: https://github.com/waldur
- Lima: https://lima-vm.io/docs/ (vz, nestedVirtualization)
- sslip.io: https://sslip.io/
- bootc: https://bootc-dev.github.io/bootc/ ; bootc-image-builder: https://github.com/osbuild/bootc-image-builder
- Spegel (P2P registry mirror): https://github.com/spegel-org/spegel
- CirrOS images: https://download.cirros-cloud.net/
- Magellan (Redfish discovery, optional): https://github.com/OpenCHAMI/magellan
- Cozystack (reference implementation of a similar stack): https://cozystack.io/

When looking things up: prefer each project's versioned docs matching the pinned versions in the repo's Renovate manifests; the KubeVirt user guide and Cilium docs change meaningfully between minors.
