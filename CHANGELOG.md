# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); the project uses semantic versioning.

## [Unreleased]
### Added
- `talu-vm` 0.2.0: **`source: import`** — populate a VM's root disk from a URL (CDI `DataVolume`
  http/s3 source) instead of the golden-image catalog, plus **`dataDisks`** for non-root volumes.
  The recovery path for a portable DR package; see `docs/architecture/drim-target.md`.
- `docs/architecture/drim-target.md` — analysis of Talu as a DRIM disaster-recovery target,
  with the restore path validated end-to-end on `rocky-phys`.
- `examples/drim/capture-openstack.sh` — capture Cinder volumes into DRIM disk artifacts using only
  the OpenStack APIs; `examples/drim-k8s/` renamed to `examples/drim/` now that it is not k8s-only.
- `drim-target.md` §10.7 — incremental capture measured on both Ceph deployments: synthetic full is
  byte-exact, `export-diff` from zero is a 23x free win over the API path, and the availability /
  encryption requirements the pattern introduces.
- lab-notes #58 (`export-diff` from zero beats `export` for full artifacts) and #59 (synthetic full
  validated byte-exact; `rbd import` can't take a stream; materialise next to the storage).
- lab-notes #56 (`rbd export` is 4.6–5.9x faster than Cinder/Glance and byte-identical) and #57
  (Cinder's "consistent group snapshot" on RBD is NOT atomic — consistency depends on snapshot order).
- lab-notes #52 (RHOSP export traps + measured export cost), #53 (a restored guest loses its device
  names — `/dev/vdX` in fstab silently stops mounting), #54 (CDI's zstd import is flaky and
  undocumented upstream — corrects #46) and #55 (`rbd export` removes ~93% of export time).
- `examples/drim/` — a worked DRIM capture/restore (manifests + scripts + an S3 helper),
  validated between two KaaS tenant clusters with a StorageClass remap, and again as a **hybrid**
  package (one `vm` + one `k8s` component) published to and retrieved from S3.
- `drim-target.md` §12 — suggested changes to the DRIM spec, from implementing it against a real
  target, including what changes for non-Talu sources (OpenStack, RKE2).
- `phys_kamaji`: raise the operator memory limit off the chart's 100Mi default — at 100Mi it is
  OOMKilled and NEW tenant clusters silently never provision (lab-notes #48).
- lab-notes #48 (Kamaji operator OOM) and #49 (PVC binding annotations must be stripped, or a
  restored claim goes to `Lost`).
- lab-notes #45 (`virt-customize` against a CDI PVC: fsGroup + LIBGUESTFS_PATH + force_tcg),
  #46 (CDI v1.65.0 decompresses zstd — measured) and #47 (a restored VM DOES re-run cloud-init,
  so most restores need no `restore.retrust`).
- Initial monorepo scaffold: `components/` (product) + `environments/` (values-only overlays),
  the customization boundary, and OSS project files (MIT).
- Remote-lab dev loop: `make lab-tunnel` / `lab-sync` / `lab-status` over an SSH tunnel.
- Rocky 10 no-KVM validation path: host `bootstrap`, Talos-in-Docker cluster create,
  Ceph-on-loop-devices helper, and the staged validation plan.
