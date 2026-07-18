# Talu — component integration reference

> Companion to the architecture reference (what and why) and the pilot plan (in what order). This document specifies the seams: exactly how components talk to each other, which objects and protocols carry each interaction, and what fails how. Treat it as the contract for implementation and review.

---

## 1. Identity fabric — Keycloak at the centre

Keycloak is the only issuer of human identity. Four consumers, four distinct integration mechanics.

### 1.1 Waldur → Keycloak: role synchronisation

- **Mechanism**: Keycloak Admin REST API, driven by a small sync component in the Waldur plugin. Event-driven on Waldur role changes, plus a periodic reconcile (drift repair).
- **Object model**: Waldur project roles materialise as Keycloak groups with the fixed convention `waldur/{project_uuid}/{role}`, role ∈ {admin, member}. Group membership mirrors Waldur assignments; groups carry no other semantics.
- **Claims**: the realm's client scopes include a `groups` mapper so every ID/access token carries full group paths. All downstream policy (Pomerium, OpenBao, RBAC) keys on these strings — never on usernames.
- **Revocation path**: removing a role in Waldur (a) removes the group membership via Admin API and (b) calls the user's session-logout endpoint. Consequence: portal access dies immediately; Pomerium and OpenBao access die at next token refresh or immediately if sessions were revoked. Documented propagation bound: ≤5 minutes passive, immediate on explicit removal.
- **Failure modes**: Keycloak unreachable → sync queues and retries; Waldur remains source of truth, reconcile heals. Group deleted manually in Keycloak → reconcile recreates (Keycloak state is derived, never edited by hand).

### 1.2 Keycloak → Pomerium: OIDC and per-route policy

- **Mechanism**: standard OIDC authorization-code flow; Pomerium is a confidential client. Route policies match token claims:

```yaml
policy:
  allow:
    and:
      - claim/groups: waldur/3f2a91bc-…/admin
```

- **Session semantics**: Pomerium re-evaluates per request against its session; claims refresh on ID-token refresh. Keep session/ID-token lifetimes short (minutes) — this is the knob that bounds role-change propagation.
- **Identity hand-off to upstreams**: Pomerium injects `X-Pomerium-Jwt-Assertion` (a signed JWT with subject, email, groups). Upstreams that make their own authorization decisions (the console shim; tenant apps that opt in) verify it against Pomerium's JWKS endpoint — never trust the bare header without signature verification.
- **Values, not structure**: route hostnames and Keycloak redirect URIs are overlay values (sslip.io in dev, real wildcard in pilot/prod).

### 1.3 Keycloak → OpenBao: human login to tenant secret namespaces

- **Mechanism**: OpenBao OIDC auth method, one enablement per tenant namespace, all pointing at the same realm. External-group mapping binds `waldur/{uuid}/admin|member` to namespace-local policies.
- **Policies**: member → CRUD on the tenant's kv mount paths; admin → member rights + SSH-CA signing roles with privileged principals + policy management inside the namespace. Platform operators hold no standing access to tenant namespaces (break-glass is a separate, audited root-token ceremony).

### 1.4 Keycloak → kubectl: OIDC for the API server

- **Mechanism**: API server OIDC flags set in Talos machine config (`oidc-issuer-url`, `oidc-client-id`, `oidc-groups-claim: groups`); users authenticate with kubelogin. Group strings map to RBAC via `Group` subjects in RoleBindings.
- **Scope**: operator convenience and phase-one technical tenants (namespace-scoped bindings). Tenant self-service never requires kubectl.

---

## 2. Secrets fabric — OpenBao and its agents

### 2.1 Topology

- 3-replica StatefulSet, integrated Raft storage on ceph-block PVCs, pod anti-affinity across nodes. TLS from the internal CA. Audit device enabled from day one, shipped to the log store.
- **Namespaces**: one per tenant (`t-<slug>-<uuid8>`, mirroring the Kubernetes namespace name). Per namespace: a kv-v2 mount (`secret/`), an SSH secrets engine mount (`ssh/`, §3), OIDC auth (§1.3), and AppRole auth for machines (§2.2).
- **Unseal**: manual unseal runbook (pilot) or external KMS (decide before production). Unseal material lives in the out-of-cluster survival kit. Sealed OpenBao ⇒ no new leases and no new VM bootstraps; running VMs keep their in-memory secrets — degradation, not outage.

### 2.2 Machine identity bootstrap — the wrapped-token flow

Per-VM sequence, executed by the Waldur plugin (or the tenant chart in phase one) at order time:

1. **Mint the role**: create/ensure an AppRole in the tenant namespace named after the VM (`role/vm-<name>`), bound to the tenant's machine policy (read on agreed kv paths; sign on the VM's SSH host-key role if used). `secret_id_ttl` short, `secret_id_num_uses: 1`.
2. **Wrap**: generate a SecretID with response wrapping — the plugin receives only a **single-use wrapping token**, TTL ≈ 10–15 min (long enough for scheduling + boot, short enough to be worthless if the spec lingers).
3. **Inject**: the wrapping token, the OpenBao URL, namespace and role name go into cloud-init user-data (rendered file `/etc/bao/bootstrap.json`). Nothing else secret enters the VM spec — what rests in etcd is a token that dies on first use or on TTL.
4. **First boot**: cloud-init enables the baked `bao-agent` unit. The agent unwraps (`sys/wrapping/unwrap`), obtains its SecretID, logs in via AppRole, and discards the bootstrap file.
5. **Tamper evidence**: if anyone unwrapped the token before the VM (etcd reader, spec leak), the legitimate unwrap fails loudly → VM's agent reports bootstrap failure → surfaces as a security event, not a silent compromise. Plugin remediation: revoke the AppRole's SecretID accessor, re-mint, reboot-inject.

### 2.3 bao-agent inside the guest

- **Delivery**: binary + systemd unit baked into golden images, disabled; enabled by cloud-init only when the flow is configured. Updates reach running guests via the platform APT repo (§8) under unattended-upgrades — never via guest-exec.
- **Configuration** (rendered by cloud-init):

```hcl
vault { address = "https://bao.internal:8200"  namespace = "t-acme-erp-3f2a91bc" }
auto_auth {
  method "approle" { config = { role_id_file_path = "...", secret_id_file_path = "...", remove_secret_id_file_after_reading = true } }
  sink "file" { config = { path = "/run/bao/token" } }
}
template { source = "/etc/bao/tpl/db.ctmpl"  destination = "/etc/app/db.env"  perms = "0600"  command = "systemctl reload app" }
```

- **Runtime behaviour**: token renewal loop; templates re-render on secret change (this is how rotation reaches workloads — a rotated kv value or a re-issued dynamic credential lands on disk and reloads the service without redeploy). API proxy/caching available on localhost for apps that prefer talking to the agent.
- **Degradation**: OpenBao unreachable → agent retries with backoff; existing rendered secrets and token remain valid until TTL; nothing crashes. Design templates so services tolerate briefly-stale credentials.
- **Network path**: guests reach `bao.internal` on the pod network; Cilium policy allows tenant-namespace → OpenBao:8200 explicitly (part of the tenant bundle), everything else denied as usual.

### 2.4 Roadmap hooks (designed-for, not built)

Dynamic database credentials (OpenBao database engine; agent template already the delivery path), per-tenant PKI issuance, and vTPM-backed cert auth replacing AppRole (machine identity bound to the virtual TPM; requires the RWX backend-storage caution from the field notes).

---

## 3. SSH chain — CA, certificates, tunnel

### 3.1 The per-tenant certificate authority

- Each tenant namespace's `ssh/` mount is a CA: `ssh/config/ca` generates the keypair; the **public** key is exported and distributed to that tenant's VMs by cloud-init as `/etc/ssh/tenant_ca.pub`.
- Golden images bake one sshd line — `TrustedUserCAKeys /etc/ssh/tenant_ca.pub` — plus `PasswordAuthentication no`. Mechanism baked, trust material injected: rule 3 of the platform.

### 3.2 Signing roles

```
ssh/roles/member : allowed principals = {keycloak username}, ttl = 15m,
                   extensions = permit-pty; key type/user cert
ssh/roles/admin  : allowed principals = {username, "admin"}, ttl = 15m
```

Role access is bound to the Keycloak groups via §1.3 — so Waldur role removal simultaneously kills portal, proxy, *and* the ability to mint privileged certs. Guest images create the `admin` user with sudo; per-user accounts are optional cloud-init extras.

### 3.3 User flow (the only shell path — no port 22 exists publicly)

1. `bao login -method=oidc -namespace=t-…` (browser SSO, same Keycloak session).
2. `bao write -field=signed_key t-…/ssh/sign/member public_key=@~/.ssh/id_ed25519.pub` → short-lived certificate.
3. `pomerium-cli tcp ssh.t-….apps.example.com:22 --listen localhost:2222` — an authenticated TLS tunnel over the single :443 listener; the route's policy gates *who may even reach* sshd.
4. `ssh -o CertificateFile=… -p 2222 admin@localhost`. sshd validates the cert against the tenant CA; principal and serial land in auth.log.

Wrap 1–3 in a `talu ssh <vm>` helper script; the underlying pieces stay standard.

- **Audit joins** (rule: one identity vocabulary): OpenBao sign entry (who minted what principals, key fingerprint, TTL) + Pomerium session log (who opened the tunnel) + sshd log (which cert serial logged in) all carry the same Keycloak username.
- **Revocation**: TTL-based (15 min); no CRL machinery. Emergency: rotate the tenant CA (one write + cloud-init refresh / accessCredentials push of the new pub key).

### 3.4 Host keys (optional hardening)

The same mount can operate as a host-key CA: VM's sshd presents a host certificate signed at bootstrap (via the VM's AppRole), users trust `@cert-authority` for the tenant domain — removing TOFU warnings. Deferred; noted because the plumbing (AppRole + agent) already exists.

---

## 4. Access plane wiring

### 4.1 Pomerium ↔ routes ↔ upstreams

- Routes are CRDs in Git (platform + admin surfaces) or created by the Waldur plugin (tenant exposure actions). Hostname convention `<name>.<t-slug-uuid8>.apps.example.com`; `allow: public` is a legal policy for genuinely public sites — still TLS-terminated, still Cilium-pinned, still one audited door.
- ACME: :80 serves HTTP-01 and redirects; cert-manager issues public certs for apps hostnames, internal CA for everything cluster-internal.

### 4.2 Cilium pinning — making the proxy non-bypassable

Tenant bundle policy (sketch):

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
spec:
  endpointSelector: {}            # all endpoints in tenant ns
  ingress:
    - fromEndpoints: [{matchLabels: {app.kubernetes.io/name: pomerium}}]   # via ns selector
    - fromEndpoints: [{matchLabels: {"k8s:io.kubernetes.pod.namespace": <this ns>}}]
  egress:
    - toEndpoints: [{matchLabels: {app.kubernetes.io/name: openbao}}]
    - toEntities: [world]          # NAT'd internet egress
    - toEndpoints: [kube-dns]
```

- **Why VM traffic obeys pod policy**: the masquerade binding NATs the guest behind the launcher pod's IP, so every VM packet carries the pod's Cilium identity — VMs and containers share one policy vocabulary. (Tier-2 secondary NICs bypass Cilium by construction; their isolation is the VLAN/bridge itself — state this in the flavor docs.)
- **Hubble** records allow/deny verdicts with identity labels; exported alongside Pomerium logs for the end-to-end access narrative.

### 4.3 LB-IPAM and the single public IP

`CiliumLoadBalancerIPPool` supplies the address; L2 announcement (or BGP where available) makes it live; Pomerium's Service claims it. Adding future dedicated-IP offerings = adding pool entries + non-IAP Services with `loadBalancerSourceRanges` — additive, never touching the main door.

### 4.4 Stable internal IPs — tier 1 via LB-IPAM

The user-chosen-internal-IP feature is native Cilium machinery, no plugin-side IPAM:

- Per tenant, the bundle includes a `CiliumLoadBalancerIPPool` over an internal, non-announced range (e.g. a /26 from a reserved internal supernet), with a `serviceSelector` matching only that tenant's namespace.
- The tenant's chosen address goes on the VM's Service as `lbipam.cilium.io/ips: "10.200.4.10"`; Cilium validates it against the pool (wrong-tenant or out-of-pool requests are simply not assigned) and the IP survives live migration because it belongs to the Service, not the pod.
- `lbipam.cilium.io/sharing-key` lets several Services (ports) share one tenant IP where a "one address, many ports" shape is wanted; cross-namespace sharing stays disabled.
- Boundary to state in tenant docs: this is a stable *service* address in front of the VM; the guest's own interface keeps its NAT-internal view. Tenants needing the fixed address *on the interface* use the tier-2 secondary-NIC flavor. Cilium offers no per-pod static IP (declined upstream by design — endpoint identity derives from the IPCache), and pod-IP persistence across migration is an OVN-Kubernetes-class capability, deliberately outside Talu's CNI scope.

---

## 5. Console path

1. Tenant clicks *Console* in Waldur → Waldur UI opens noVNC over its own HTTPS origin (websocket #1).
2. Waldur's KubeVirt plugin authorizes against the Waldur session/role, selects the tenant's namespace, and opens websocket #2 to `…/apis/subresources.kubevirt.io/v1/namespaces/<ns>/virtualmachineinstances/<vm>/vnc` using the **per-tenant ServiceAccount** whose Role allows only `virtualmachineinstances/vnc` and `…/console` in that namespace.
3. virt-api streams from the launcher's VNC socket; Waldur splices the websockets.

Properties: no graphical console ever listens publicly; blast radius of a compromised credential is one namespace (per-tenant SA discipline); serial console (`/console`) is the fallback when guest networking is broken — which is precisely when a console matters. Console-open events log with the Keycloak username. Infrastructure requirement: every proxy in front of Waldur passes websockets with long idle timeouts.

---

## 6. VM identity injection — who writes what into a guest

Composition of the NoCloud payload, rendered by the plugin/chart per VM:

| Fragment | Producer | Content |
|---|---|---|
| meta-data | plugin | instance-id, hostname (= VM name) |
| network-config | plugin | static v2 config only for tier-2 secondary NICs; primary NIC uses the in-pod DHCP |
| user-data: users/keys | plugin from tenant input | initial authorized keys (day-2 keys go via SSH CA or accessCredentials) |
| user-data: trust | plugin | platform CA root install; `tenant_ca.pub` write |
| user-data: bao bootstrap | plugin | §2.2 file + unit enable |
| user-data: update policy | plugin from order attribute | enable or mask unattended-upgrades timer |

- **DNS search domain**: set `dnsConfig.searches: [<ns>.svc.cluster.local]` on the VMI (with `dnsPolicy: None` + cluster DNS server) — the in-pod DHCP hands the guest a resolv.conf where bare `database` resolves. This, plus the per-VM Service (selector `vm.kubevirt.io/name: <vm>`), is the whole discovery mechanism.
- **accessCredentials** (qemu-guest-agent propagation) is the *running-VM* channel for SSH public keys — used for "add my key" without reboot and for emergency key injection; never for secrets.

---

## 7. Metrics → billing

- **Sources**: KubeVirt exporters (`kubevirt_vmi_*` series: vcpu seconds, memory working set, storage/network bytes), kube-state-metrics (object counts), Ceph and Cilium exporters — all namespace-labelled.
- **Contract**: Waldur polls the Prometheus HTTP API on a fixed cadence (align to billing granularity, e.g. 5 min) with per-namespace PromQL recorded in the repo; the *same queries* render tenant dashboards and generate billing records — what the tenant sees is what's invoiced.
- **Freshness indicator** inputs: `VirtualMachineInstance.status.guestOSInfo` (via guest agent) + platform APT repo access logs, joined per VM — no in-guest access.
- **Recording rules** pre-aggregate the billing set so Waldur's polls stay cheap and retention pressure stays low (the VictoriaMetrics decision point).

---

## 8. Trust and supply chain

- **Internal CA**: cert-manager `ClusterIssuer`; issues for OpenBao, Pomerium-internal, zot, virt-api path, registry. Root baked into golden images and into `make dev-trust`. Rotation: overlapping roots (bake new + old, flip issuance, retire old at image cadence).
- **Image chain**: Git (Containerfile) → CI builds, `virt-sparsify` → cosign-signed containerDisk → zot → DataImportCron imports on digest change (admission verifies signature) → VolumeSnapshot golden source → tenant COW clones.
- **APT repo**: CI-built signed .debs (bao-agent, helpers), static hosting behind a public Pomerium route (`allow: public` — repos must be reachable from guests without sessions; integrity comes from GPG, not transport auth). Repo origin whitelisted in baked unattended-upgrades config.

---

## 9. Upgrade integrations

- **tuppr ↔ Talos**: `kubernetesTalosAPIAccess` grants the upgrade job `os:admin` scoped to its namespace (lock that namespace down accordingly). Jobs call the Talos upgrade API from a *different, healthy* node.
- **Gates (CEL)**: Ceph `HEALTH_OK`; no `VirtualMachineInstanceMigration` in Running phase; node Ready; **post-boot `nodeInfo.osImage` == target** (silent A/B rollback catch). Post-hook: alert on ContainerStatusUnknown debris.
- **Drain ↔ KubeVirt**: eviction API → `evictionStrategy: LiveMigrate` → virt-controller creates VMIMs (bounded by `parallelOutboundMigrationsPerNode`); tuppr's per-node timeout must exceed worst-case drain, computed from the model below.

**Drain-time model** (the same math as the capacity planner; keep the constants in one place and cite them in the tuppr values file):

```
t_migrate(vm) ≈ (vm_RAM_GiB × 8 / NIC_Gbps) × dirty_factor + t_setup
drain(node)   ≈ ceil(VMs_on_node / P_out) × t_migrate(avg)          # P_out = parallelOutboundMigrationsPerNode (default 2)
tuppr policy.timeout(node) ≥ drain(node) × safety                   # safety ≥ 2; default 30 m is NOT enough for large nodes
```

- Constants as used platform-wide: `dirty_factor = 1.3` (pre-copy re-transmits dirtied pages; idle guests ~1.0, busy databases 2+), `t_setup = 8 s` (target pod creation, RBD attach, handshake), `safety = 2`.
- Worked example, reference node: 20 VMs × 8 GiB on 25 GbE → t_migrate ≈ 8×8/25×1.3+8 ≈ 11 s → drain ≈ 10 × 11 s ≈ 2 min → timeout ≥ 4 min. Large node: 20 VMs × 32 GiB on 10 GbE → t_migrate ≈ 41 s → drain ≈ 7 min → timeout ≥ 15 min. Set per node class, not one global.
- **Throttle gotcha**: verify `bandwidthPerMigration` for the deployed KubeVirt version — historically it defaulted to a 64 MiB/s cap, which silently invalidates this model (a 32 GiB VM becomes ~9 min alone). Set it explicitly to match NIC headroom.
- **Convergence controls** for guests whose dirty rate exceeds bandwidth: `allowAutoConverge` (CPU-throttles the guest until pre-copy converges) and `completionTimeoutPerGiB` (abort bound); post-copy exists but trades a failure mode (network blip mid-post-copy kills the VM) — keep it off by default, document it as a per-VM opt-in for known-hot workloads.
- The model's inputs (NIC speed, VM density, per-class RAM) come from the capacity planner; when hardware changes, the tuppr timeouts are part of the same review.
- **KubeVirt promotion gate**: on dev-shared, after a KubeVirt bump, a VM created *before* the bump must still live-migrate — only then the version merges toward pilot/prod.
- **Renovate**: every pinned version (Talos schematic tag, component charts, golden-image bases, tuppr itself) flows as PRs; merge = the maintenance decision; Git history = the maintenance log.

---

## 10. External manager contract (recap for integrators)

Everything above reduces, for an external billing/management platform, to:

1. **Write** labelled Kubernetes objects (tenant bundle, DataVolumes, VirtualMachines, Pomerium routes, OpenBao role objects via the plugin's operator or direct API) — ownership label `talu.io/project-uuid` on every object is the join key.
2. **Watch** object status — the only progress/health signal (DataVolume phases, VMI conditions, route readiness).
3. **Read** the Prometheus HTTP API for usage.
4. **Delegate identity** to the shared OIDC realm and express authorization as group membership.

Waldur is the reference implementation of this contract; nothing in Talu may assume it specifically.
