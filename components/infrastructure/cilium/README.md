# cilium

**Responsibility:** eBPF datapath, kube-proxy replacement, LB-IPAM + L2, WireGuard, Hubble, tenant network policy.

**Upstream:** <https://docs.cilium.io/en/stable/> — see also [`docs/architecture/networking.md`](../../../docs/architecture/networking.md).

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
