# network-policy

**Responsibility:** multi-tenant network isolation — **Layer A**, the cluster-wide, non-overridable
tenant egress deny that closes **KT-06**.

## The gap this closes (root cause)

Egress was never enforced: no Cilium policy selected tenant endpoints for **egress**, so tenant egress
was allow-all. KT-06 (tenant VM → management `kube-apiserver`) was stopped only by **authn** (a 401),
not the network; KT-07 (cross-tenant) leaned on distinct CAs. The network itself let tenant workloads
address the substrate control plane.

## The three layers

| Layer | Where | What |
|---|---|---|
| **A — cluster-wide deny** | this component (`CiliumClusterwideNetworkPolicy`) | selects any `talu.io/project-uuid` endpoint; **egressDeny** to `kube-apiserver`. Deny beats allow, so a tenant cannot re-open it. |
| **B — per-tenant baseline** | tenant/cluster charts (`netpol-baseline.yaml`, planned) | default-deny egress + allow-list (own ns, cluster DNS, own LB/logging) and the mandatory `fromEntities: [host, remote-node, health]` ingress. Cross-tenant isolation (KT-07) falls out. |
| **C — security groups** | tenant chart (`securitygroups.yaml`, exists) | cloud-style **additive** allow rules on the tenant's VMs. |

## The two things that make Layer A safe

1. **`enableDefaultDeny.egress: false`.** In this Cilium, a policy that selects an endpoint normally
   flips that direction to **default-deny** — which for an egress deny-only policy would blackhole ALL
   tenant egress (internet, DNS). This flag keeps the `egressDeny` rules enforced while leaving every
   other egress path allowed. (Same footgun the `loki-ingress-policy` comment documents, opposite fix:
   there an allow-list was needed; here we explicitly opt out of default-deny.)
2. **Reserved identities, not CIDRs.** `toEntities: [kube-apiserver]` is IP-family-agnostic (most of
   the IPv6 story for free) and always resolves to the real apiserver set.

It does **not** catch the Kamaji control-plane pods (they carry no `talu.io/project-uuid`), so hosted
tenant APIs keep working; and it blocks tenant→**mgmt**-API without touching tenant→**tenant**-API
(a LoadBalancer IP, not the `kube-apiserver` identity).

## Staged rollout (CCNP has no audit mode)

Layer A ships denying `kube-apiserver` only — precise and low-risk. The optional `host`/`remote-node`
deny is **commented out** in `tenant-egress-deny.yaml`: enable it per environment only after a
**Hubble audit** under real traffic confirms nothing legitimate crosses those entities:

```sh
# watch tenant egress that WOULD be dropped by the host/remote-node rule before enabling it
hubble observe --namespace <tenant-ns> --to-identity host --to-identity remote-node -f
```

## Validation

Re-run **KT-06′/KT-07′** expecting a **network DROP** (a Hubble drop record), not a 401. Confirm no
tenant DNS/internet regression and that Kamaji CP pods + tenant LB traffic are unaffected. Applied on
the physical lab by the `phys_netpol` role (after Cilium + tenancy).

This is a reusable base — part of `components/` (the product). Adopters do **not** edit it.
