# cilium

**Responsibility:** eBPF datapath, kube-proxy replacement, LB-IPAM + L2, WireGuard, Hubble, tenant network policy.

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
