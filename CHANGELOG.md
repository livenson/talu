# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); the project uses semantic versioning.

## [Unreleased]
### Added
- `talu-vm` 0.2.0: **`source: import`** — populate a VM's root disk from a URL (CDI `DataVolume`
  http/s3 source) instead of the golden-image catalog, plus **`dataDisks`** for non-root volumes.
  The recovery path for a portable DR package; see `docs/architecture/drim-target.md`.
- `docs/architecture/drim-target.md` — analysis of Talu as a DRIM disaster-recovery target.
- Initial monorepo scaffold: `components/` (product) + `environments/` (values-only overlays),
  the customization boundary, and OSS project files (MIT).
- Remote-lab dev loop: `make lab-tunnel` / `lab-sync` / `lab-status` over an SSH tunnel.
- Rocky 10 no-KVM validation path: host `bootstrap`, Talos-in-Docker cluster create,
  Ceph-on-loop-devices helper, and the staged validation plan.
