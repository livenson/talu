# upgrades

**Responsibility:** tuppr TalosUpgrade/KubernetesUpgrade CRs + CEL health gates (Ceph HEALTH_OK, osImage==target).

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
