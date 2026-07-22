# ci — golden-image pipeline (forge-agnostic + in-cluster)

The golden-image build runs **wherever there's privileged podman** (no `/dev/kvm` needed) — never on a
cluster node. Two homes, one shared core:

- **`image-build.sh`** — the forge-agnostic core: `build (bootc) → scan (Trivy) → publish → sign (cosign)`.
  Gates (`SCAN`/`SIGN`) are **togglable** (off by default; enforce in prod). Wraps `../images/build-bootc.sh`.
- **`github/build-image.yml`** — GitHub Actions wrapper (copy to `.github/workflows/`). Triggers: weekly
  schedule + `workflow_dispatch` (manual/CVE) + `images/**` changes. Keyless cosign via OIDC.
- **`gitlab/.gitlab-ci.yml`** — GitLab CI wrapper (needs a privileged runner).
- **In-cluster option:** `../components/infrastructure/image-builds/` — a privileged CronJob that clones the
  repo and runs `image-build.sh`, pushing to in-cluster zot. Zero external dependency; needs a real node
  with loop devices (fragile on the nested lab).

**Flow:** build → push signed containerDisk to **zot** (`components/infrastructure/zot/`) → a CDI
`DataImportCron` (`components/infrastructure/cdi/`) rolls the `DataSource` → new VMs get it via the tenant
chart `sourceRef`; running VMs self-update via bootc. Promote `testing`→`stable` after acceptance. The
decisions behind it: [`docs/architecture/README.md#design-decisions`](../docs/architecture/README.md#design-decisions).

The second CI pipeline — plugin/chart tests from committed state, `rocky-sandbox` as the e2e gate — is
still a stub (fork-and-track).
