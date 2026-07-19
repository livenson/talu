# rook-ceph

**Responsibility:** Rook Ceph — RBD block storage, snapshots, smart clones, RWX for live migration.

**Upstream:** <https://rook.io/docs/rook/latest/> · [ceph-csi](https://github.com/ceph/ceph-csi). The lab uses external [MicroCeph](https://canonical-microceph.readthedocs-hosted.com/) CephFS instead — see [`docs/development/lab-notes.md`](../../../docs/development/lab-notes.md) #14/#15.

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
