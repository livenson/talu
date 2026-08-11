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
- `examples/drim-k8s/` — a worked DRIM `type: k8s` capture/restore (manifest + scripts), validated
  between two KaaS tenant clusters with a StorageClass remap.
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
