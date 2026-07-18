# rook-ceph

**Responsibility:** Rook Ceph — RBD block storage, snapshots, smart clones, RWX for live migration.

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
