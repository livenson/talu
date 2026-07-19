# cdi

**Responsibility:** Containerized Data Importer — DataVolume/DataImportCron, golden-image import as VolumeSnapshot sources.

**Upstream:** <https://github.com/kubevirt/containerized-data-importer> · [DataVolume user guide](https://kubevirt.io/user-guide/storage/disks_and_volumes/).

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
