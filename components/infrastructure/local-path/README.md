# local-path

**Responsibility:** local-path-provisioner — CDI scratch + bootstrap PVCs only. Never the default StorageClass.

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
