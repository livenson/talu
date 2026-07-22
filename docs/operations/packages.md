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

### 1. Build — `build-deb.sh` + `build-rpm.sh`
Renders the package from a CA pubkey file, in **both** formats: `.deb` (pure coreutils+tar+ar, no
`dpkg-deb`) and `.rpm` (`rpmbuild`). Each installs `/etc/ssh/talu_ca.pub` (one CA key per line — two
during a rotation's dual-trust window) + `/etc/ssh/sshd_config.d/60-talu-ca.conf`, and the post-install
**reloads** sshd (never restart — a live session, including the platform's own, is never dropped).

### 2. Index + sign — `apt-reindex.sh` + `rpm-reindex.sh`
`apt-reindex.sh` generates a **flat apt repo** (`Packages`, `Packages.gz`, `Release`) in pure shell;
`rpm-reindex.sh` runs `createrepo_c`. With `GPG_SIGN=true` both are **signed** — apt gets `InRelease` +
`Release.gpg`, rpm gets `repomd.xml.asc`, and the pubkey is published at `/talu-ca.asc`. Guests then pin
it (`signed-by=…` for apt, `repo_gpgcheck=1` for dnf) and drop `[trusted=yes]`. Unsigned still works on a
lab (`[trusted=yes]` skips the signature; apt still checks the `Release` hashes the indexer computes).

### 3. Repo — `components/platform/pkg-repo/`
A tiny **nginx** (unprivileged) serving a PVC over HTTP, in the `golden-images` namespace next to zot.
Guests on the pod network reach it at `http://pkg-repo.golden-images.svc/deb/`. Opt-in:
```sh
kubectl apply -k components/platform/pkg-repo      # golden-images ns comes from the image catalog
```

### 4. Publish — `publish.sh <version>` (host) or the in-cluster Job (production)
`publish.sh` reads the current CA pubkey, builds deb **and** rpm (when the toolchain is present),
indexes + signs both, and syncs into the `pkg-repo` pod. `dev/lab/ca-rotate.sh` calls it host-side on the
lab. **In production**, `components/platform/pkg-repo/publish-job/` runs the *same* `publish.sh` in-cluster
(clones the repo, `dnf`-installs the toolchain, GPG-signs from the `talu-pkg-signing` Secret) — mirroring
the golden-image build CronJob, so no host needs the tooling:
```sh
kubectl -n golden-images create secret generic talu-pkg-signing --from-file=private.asc=<armored-key>
kubectl apply -k components/platform/pkg-repo/publish-job     # bump VERSION in the Job per publish
```

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

## Validated on the lab
Both formats install from the in-cluster repo — Ubuntu 24.04 via apt, CentOS Stream 9 via dnf — the file
is package-owned (`dpkg -S` / `rpm -qf`), a v1→v2 `apt upgrade` is **reboot-less**, and with signing on, a
guest **verifies** the `InRelease` signature (`signed-by`, no `trusted=yes`).

## Optimization (fast-follow)
Bake a **builder image** (toolchain pre-installed) so the publish Job runs non-root with no runtime
`dnf install`. Everything else — deb + rpm build, flat-repo index, `createrepo`, GPG signing, the
in-cluster repo, and the in-cluster publish Job — is built and lab-validated.
