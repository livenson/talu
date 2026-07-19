# Installing Talu on your own hardware

> The zero-hardware way to try Talu is the [Rocky 10 quick-mode](../development/validation-plan.md).
> This page is the outline for a real (KVM-capable) deployment; it fills in as components land.

Decide-once items (Phase 2 of the pilot plan — annoying to change later):

- **IP / CIDR plan** — node IPs + future node IPs, control-plane VIP, LB-IPAM pool. Pod and
  service CIDRs sized for the *final* cluster (effectively immutable).
- **Cilium IPAM mode** — immutable on a live cluster; decide at bootstrap.
- **DNS** — `api.` `id.` `bao.` `registry.` `portal.` and the `*.apps.<site>` wildcard;
  whether the wildcard carries a region label.
- **Forge** — Flux pulls over HTTPS with a read-only deploy token (outbound-only). The forge
  sits outside the cluster's failure domain.
- **Secrets** — SOPS/age or OpenBao; the repo ships only `*.example` stubs.

Then: create your overlay from `environments/example` (see [`../customize/`](../customize/)),
point Flux at it, and follow the pilot plan's phase order.
