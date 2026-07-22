# OS packages — build, repo, and delivery to guests

Talu ships some **cluster-specific config into guest VMs as OS packages** rather than baking it into
images or hand-writing files. The first (and today only) such package is **`talu-ca-trust`** — the SSH
User CA trust — but the mechanism is general: anything a guest should *pull and auto-update* fits here.

**Why a package.** dpkg/rpm **own** the files a package installs, so an `apt/dnf upgrade` replaces them
cleanly. That's what makes the SSH User CA **rotatable without recreating VMs and without the platform
ever SSHing into a guest** — see [rotation.md](rotation.md). It also sidesteps two traps that a
cloud-init-written file hits (lab-notes #35): the ostree `/etc`-merge (bootc won't overwrite a
locally-modified `/etc` file) and cloud-init's file becoming an unmanaged local override.

This is the OS-package analog of Talu's **golden-image** pipeline (build a bootc image → push to the
in-cluster **zot** registry → guests pull via CDI). Packages are the same shape, one layer down.

## The pipeline

```
CA pubkey (pomerium-user-ca ConfigMap)
   │  build-deb.sh            → talu-ca-trust_<ver>_all.deb   (owns /etc/ssh/talu_ca.pub + sshd drop-in)
   │  apt-reindex.sh          → Packages(.gz) + Release        (flat apt repo metadata; pure shell)
   ▼  publish.sh
pkg-repo  (components/platform/pkg-repo — nginx serving a PVC over HTTP, in golden-images ns)
   ▼  http://pkg-repo.golden-images.svc/deb/
guests    (two delivery paths, by OS model — below)
```

### 1. Build — `images/ca-trust/build-deb.sh`
Renders the `.deb` from a CA pubkey file. The package installs `/etc/ssh/talu_ca.pub` (one CA key per
line — two during a rotation's dual-trust window) + `/etc/ssh/sshd_config.d/60-talu-ca.conf`, and its
`postinst` **reloads** sshd (never restart — a live session, including the platform's own, is never
dropped). Built with only coreutils + tar + ar (no `dpkg-deb`), so it builds on the rpm-based lab host.

### 2. Index — `images/ca-trust/apt-reindex.sh`
Generates a **flat apt repo** (`Packages`, `Packages.gz`, `Release`) over a dir of `.debs`, in pure
shell. Guests use `deb [trusted=yes] http://<repo>/ ./`. `[trusted=yes]` skips the GPG *signature*, but
apt still verifies the `Release` hashes against `Packages`, which the indexer computes — so the repo
works unsigned. **Production: GPG-sign the `Release`** (and drop `trusted=yes`).

### 3. Repo — `components/platform/pkg-repo/`
A tiny **nginx** (unprivileged) serving a PVC over HTTP, in the `golden-images` namespace next to zot.
Guests on the pod network reach it at `http://pkg-repo.golden-images.svc/deb/`. Opt-in:
```sh
kubectl apply -k components/platform/pkg-repo      # golden-images ns comes from the image catalog
```

### 4. Publish — `images/ca-trust/publish.sh <version>`
Reads the current CA pubkey (`pomerium-user-ca`), builds the `.deb`, re-indexes, and syncs the repo into
the `pkg-repo` PVC. On the lab it builds on the host and `kubectl cp`s in; **in production run the same
steps as an in-cluster Job** (reads the ConfigMap, writes the PVC) — the way the image pipeline uses a
build Job. `dev/lab/ca-rotate.sh` calls `publish.sh` automatically when `pkg-repo` is deployed.

## Delivery to guests — two paths, by OS model

| Guest | Install | Auto-update | Reboot? |
|---|---|---|---|
| **mutable** (ubuntu containerDisk, package-mode) | tenant chart `caTrust.package=true` → cloud-init `packages: [talu-ca-trust]` from `caTrust.aptRepoLine` | `unattended-upgrades` (matches Release `origin=talu`) | **no** — sshd reload |
| **bootc** (centos-bootc golden image) | `dnf install talu-ca-trust` **baked into the image** | the bootc image update | yes (graceful) |

Only the mutable path needs the repo; bootc guests carry the package in the image and ride the
zot→bootc channel. The default (`caTrust.package=false`) hand-writes the trust file instead — simplest
and repo-free, but the CA is then only rotatable by recreating the VM (fine for ephemeral containerDisk
VMs).

**Validated on the lab:** build → index → serve → an Ubuntu 24.04 guest `apt install`s `talu-ca-trust`
from `http://pkg-repo.golden-images.svc/deb/`, and a later `apt upgrade` moves it v1→v2 **reboot-less**
(`dpkg -l` confirms), with the file dpkg-owned throughout.

## Not yet built (fast-follow)
- An **rpm** (`build-rpm.sh` via `fpm`/`rpmbuild`) + `createrepo` for the bootc/CentOS side. The `.deb`
  path and the repo are done; the rpm is symmetric.
- The **in-cluster build/publish Job** (so publishing doesn't need a host with the tooling), and
  **GPG-signing** the repo for production.
