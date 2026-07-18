# kubevirt

**Responsibility:** KubeVirt operator + CR — VM lifecycle, live migration, hotplug (feature-gated).

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
