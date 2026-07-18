# access

**Responsibility:** Pomerium IAP — per-route policy, SNI fan-out on :443; Cilium pinning policy templates.

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
