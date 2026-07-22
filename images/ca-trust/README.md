# ca-trust — the `talu-ca-trust` package

The SSH User CA trust delivered as a **package the guest OS owns and auto-updates**, so rotating the
Pomerium User CA is a package upgrade — not a re-provision, and **the platform never SSHes into a guest**.

## What it contains
- `/etc/ssh/talu_ca.pub` — the CA public key(s) this cluster's VMs trust (one line per CA; two during a
  rotation's dual-trust window).
- `/etc/ssh/sshd_config.d/60-talu-ca.conf` — `TrustedUserCAKeys …` + `PasswordAuthentication no`.
- `postinst` — **reloads** sshd (never restart; a live session, including the platform's own, is never dropped).

Because dpkg/rpm own the trust file, `apt/dnf upgrade` replaces it cleanly on rotation — sidestepping the
ostree `/etc`-merge (bootc won't overwrite a locally-modified `/etc` file) and the cloud-init
local-override problem.

## Build
```sh
# from the live CA pubkey (the pomerium-user-ca ConfigMap):
kubectl -n pomerium get cm pomerium-user-ca -o jsonpath='{.data.user_ca\.pub}' > ca.pub
images/ca-trust/build-deb.sh ca.pub 1 ./repo          # → repo/talu-ca-trust_1_all.deb
```
`build-deb.sh` needs only coreutils + tar + ar (no `dpkg-deb`), so it builds on Rocky too. **Validated:**
the resulting `.deb` installs on Ubuntu 24.04 and `dpkg -S /etc/ssh/talu_ca.pub` shows it package-owned.

## Two delivery paths (matched to the guest OS)
| Guest | Install | Auto-update / rotate |
|---|---|---|
| **mutable** (ubuntu containerDisk, package-mode) | tenant chart `caTrust.package=true` → cloud-init `packages: [talu-ca-trust]` from your apt repo | `unattended-upgrades` (reboot-less) |
| **bootc** (centos-bootc golden image) | `dnf install talu-ca-trust` baked into the image | the bootc image update (reboot) |

The in-cluster repo is [`components/platform/pkg-repo/`](../../components/platform/pkg-repo/); build +
index + publish to it with `apt-reindex.sh` + `publish.sh`. Point `caTrust.aptRepoLine` at it (default:
`http://pkg-repo.golden-images.svc/deb/`). Full pipeline: [`docs/operations/packages.md`](../../docs/operations/packages.md).

## Rotate
Drive the dual-trust rotation with [`dev/lab/ca-rotate.sh`](../../dev/lab/ca-rotate.sh)
(`prepare` → roll the package → `switch` → grace → `retire`). Full flow:
[`docs/operations/rotation.md`](../../docs/operations/rotation.md).

## Not yet built (fast-follow)
An **rpm** for the bootc/CentOS side (`build-rpm.sh` via `fpm`/`rpmbuild` + `createrepo`), an in-cluster
**build/publish Job** (so it doesn't need a host with the tooling), and **GPG-signing** the repo for
production. The `.deb` path, the flat-repo index, the in-cluster repo, and the rotation logic are done
and lab-validated.
