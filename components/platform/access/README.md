# access

**Responsibility:** Pomerium IAP — per-route policy, SNI fan-out on :443; Cilium pinning policy templates.

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.

## Per-VM SSH access — how it generalizes

A VM becomes SSH-reachable (relying on OpenBao short-lived certs) when four objects exist:

1. `Service <vm>-ssh` — selects `kubevirt.io/vm: <vm>`, port 22.
2. `CiliumNetworkPolicy <vm>-ssh-pin` — ingress to :22 only from the Pomerium namespace.
3. A **Pomerium route** `tcp+https://ssh-<vm>.<host>:22 → <vm>-ssh.<ns>.svc:22`.
4. An **OpenBao role** scoped to the tenant's principals (`ssh/roles/<vm>`, ttl 15m).

**The correct way to create them: the tenant chart renders all four from tenant values**,
each stamped `talu.io/project-uuid`. Flux reconciles and prunes them together — one
source of truth, auditable, clean GC. Generation happens at reconcile time (in Git),
not at admission time.

- The Pomerium **route** is rendered into the Pomerium config from the set of Services
  labelled `talu.io/ssh-expose: "true"` (declarative — add a VM = add a list entry).
  On the lab the static-config ConfigMap is re-rendered from that label; in production
  either keep that render step in the chart or switch to the Pomerium Ingress Controller
  so each route is an `Ingress` object (confirm OSS TCP-route support first).
- `vm-ssh-access.template.yaml` is the chart-rendered shape (objects 1–2, route + role
  as comments).

## Kyverno — enforcement, not generation

Kyverno (`kyverno-guardrails.yaml`) **validates the invariants**, it does not create the
plumbing: every exposed VM Service must carry `talu.io/project-uuid` and have its pinning
policy; a hardened VM must not re-enable SSH password auth. Kyverno cannot edit the
Pomerium config blob or create the OpenBao role, so it can't be the generator — the chart
is. (Kyverno `generate` *could* own objects 1–2, but then the chart must not also emit
them; don't double-own.)

## Lab helpers

`dev/lab/expose-vm.sh <vm> <ns>` stands in for the chart on the throwaway lab: it creates
the Service + pinning policy, re-renders the Pomerium routes from the `talu.io/ssh-expose`
label, and opens the OIDC-gated tunnel. `dev/lab/vm-ssh.sh <vm> [principal]` then gets an
OpenBao-signed 15-min cert and SSHes in through that tunnel.
