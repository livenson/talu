# access

**Responsibility:** Pomerium IAP — per-route policy, SNI fan-out on :443; **Native SSH proxy + SSH
User CA**; Cilium pinning policy templates.

**Upstream:** [Pomerium Native SSH](https://www.pomerium.com/docs/capabilities/native-ssh-access) · [Pomerium docs](https://www.pomerium.com/docs/).

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.

## Per-VM SSH access — how it generalizes

Access is **Pomerium Native SSH**: Pomerium is the SSH proxy *and* the SSH User CA. Users run
`ssh <principal>@<vm>@ssh.<host> -p <port>`, authenticate via OIDC in the browser, and Pomerium
issues the short-lived cert itself — no OpenBao, no tunnel, stock `ssh` client. A VM becomes
reachable when these objects exist:

1. Cloud-init **Secret `<vm>-userdata`** — the VM's `cloudInitNoCloud.secretRef`; carries the
   Pomerium User CA trust (`TrustedUserCAKeys`) **and** any guest secrets (out of the VM manifest).
2. `Service <vm>-ssh` — selects `kubevirt.io/vm: <vm>`, port 22.
3. `CiliumNetworkPolicy <vm>-ssh-pin` — ingress to :22 only from the Pomerium namespace.
4. A **Pomerium `ssh://<vm>` route** → `ssh://<vm>-ssh.<ns>.svc:22`, policy scoped to tenant members.
   The route **name** is the middle token users type (`ssh …@<vm>@…`).

Pomerium itself needs a one-time **User CA + host keys** (Secret `pomerium-ssh`) and publishes the
User CA **public** key as ConfigMap `pomerium-user-ca` (what the VM generator bakes into cloud-init).

**The correct way to create the per-VM objects: the tenant chart renders all four from tenant
values**, each stamped `talu.io/project-uuid`. Flux reconciles and prunes them together — one
source of truth, auditable, clean GC. Generation happens at reconcile time (in Git), not at
admission time. `vm-ssh-access.template.yaml` is the chart-rendered shape (objects 1–3; the
`ssh://` route as a comment).

- The Pomerium **route** is rendered into the Pomerium config from the set of Services labelled
  `talu.io/ssh-expose: "true"` (declarative — add a VM = add a route). On the lab the static-config
  ConfigMap is re-rendered from that label; in production keep that render step in the chart or move
  to the Pomerium Ingress Controller so each route is an object.
- **Guest secrets** ride in via the cloud-init Secret (KubeVirt `secretRef`) — no guest agent, no
  OpenBao. Dynamic rotation would need a guest agent (KubeVirt `accessCredentials`); out of scope here.

## Kyverno — enforcement, not generation

The Kyverno **engine** lives in [`../kyverno/`](../kyverno/README.md) (installed as its own component);
this `kyverno-guardrails.yaml` is one of the policies it enforces.
Kyverno **validates the invariants**, it does not create the plumbing:
every exposed VM Service must carry `talu.io/project-uuid` and have its pinning policy; a hardened
VM must not re-enable SSH password auth. Kyverno cannot edit the Pomerium config blob, so it can't
be the generator — the chart is. (Kyverno `generate` *could* own objects 2–3, but then the chart
must not also emit them; don't double-own.)

## Lab helpers

`dev/lab/expose-vm.sh <vm> <ns>` stands in for the chart on the throwaway lab: it creates the
Service + pinning policy and re-renders the Pomerium config (base HTTP routes + SSH-server block +
one `ssh://<vm>` route per `talu.io/ssh-expose` label). `dev/lab/vm-ssh.sh <vm> [principal]` is a
thin wrapper over `ssh <principal>@<vm>@ssh.<domain> -p <port>`. `dev/lab/gen-vm-manifests.sh`
emits the full per-VM bundle (cloud-init Secret + VM + Service + pinning) for an external
orchestrator to apply. `dev/lab/gc-orphans.sh [--delete]` detects (and cleans) orphaned plumbing —
a Service/pin/Secret/`ssh://` route left behind when a manually-exposed VM is deleted (chart-managed
tenants never orphan, since Flux GCs the bundle together); dry-run by default.

**Rotating the User CA:** the CA is generated once by the `identity_pomerium` role; rotate it without
locking guests out via `dev/lab/ca-rotate.sh` (dual-trust: `prepare` → roll the `talu-ca-trust` package
→ `switch` → `retire`). VMs get the new trust through the package/ConfigMap — the platform never SSHes
into a guest. See [`docs/operations/rotation.md`](../../../docs/operations/rotation.md).
