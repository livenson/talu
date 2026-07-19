# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); the project uses semantic versioning.

## [Unreleased]
### Added
- Initial monorepo scaffold: `components/` (product) + `environments/` (values-only overlays),
  the customization boundary, and OSS project files (Apache-2.0).
- Remote-lab dev loop: `make lab-tunnel` / `lab-sync` / `lab-status` over an SSH tunnel.
- Rocky 10 no-KVM validation path: host `bootstrap`, Talos-in-Docker cluster create,
  Ceph-on-loop-devices helper, and the staged validation plan.
