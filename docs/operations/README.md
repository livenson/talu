# Operations & runbooks

Runbooks for the things the cluster cannot rebuild itself from — the out-of-cluster survival
kit — and for single-node incidents.

**Available today:**

- **[`node-maintenance.md`](node-maintenance.md)** — take a node out of / back into service and do
  **rolling Talos / Kubernetes upgrades**, **live-migrating each node's VMs off first** (KubeVirt
  `evictionStrategy: LiveMigrate` + the `kubevirt.io/drain` taint). `make node-drain` / `node-uncordon`
  / `talos-upgrade` (dry-run by default). Single-node lab caveat: it refuses to evacuate (nowhere to
  migrate) rather than powering VMs off.
- **[`rotation.md`](rotation.md)** — rotating the **SSH User CA** (dual-trust, zero lockout, via the
  `talu-ca-trust` package — the platform never SSHes into guests) with `dev/lab/ca-rotate.sh`, plus
  platform-secret rotation (`secret-rotate.sh`) and the cert-manager auto-renewal note.
- **[`secrets.md`](secrets.md)** — **secrets at rest with SOPS + age**: the model (encrypt only
  `data`/`stringData`; Flux and ansible decrypt the *same* files), first-time key setup, the
  kustomize-does-not-decrypt trap, and the phased migration off the committed demo plaintext. Enforced
  by a **gitleaks** CI gate. Component: `components/platform/secrets/`.
- **[`kaas-deploy.md`](kaas-deploy.md)** — **deploying & accessing a managed Kubernetes (KaaS) tenant
  cluster**: the graduated `talu-cluster` chart (prereqs incl. the `ClusterResourceSet` gate, what gets
  created, the direct-mount graduation insight), verification, and **access** — the Pomerium
  impersonation `kubectl` route (validated: SA token → 403, +Impersonate-User → 200) and the Headlamp
  console. Validated end-to-end on the physical lab.
- **[`upgrades.md`](upgrades.md)** — **version upgrades** across the four surfaces (Talos/k8s substrate,
  platform components, KaaS tenants, CAPI providers). The **compat-matrix** (KubeVirt v1.8 → k8s ≤ 1.35)
  enforced by CI + Kyverno + Renovate; the tuppr adoption plan and the drain-must-live-migrate crux.
  Component: `components/platform/upgrades/`.
- **[`packages.md`](packages.md)** — how cluster-specific config reaches guests as **OS packages**:
  build → flat apt repo → the in-cluster `pkg-repo` → mutable-guest auto-update (or baked into bootc
  images). Validated end-to-end (install + reboot-less v1→v2 upgrade).
- **[`backup-restore.md`](backup-restore.md)** — the three backup tiers (Talos etcd snapshot ·
  KubeVirt `VirtualMachineSnapshot` · Velero + file-system backup to S3, **Garage**) with **explicit
  backup and restore flows**, validated end-to-end on the lab including a destroy-and-restore that
  recovered volume **data**, plus an automated weekly **DR drill** (`restore-test.yaml`). Read the
  `hostPath`/`local-path` gotcha before trusting a backup.
- **Host lockout recovery** (the Docker/network/MTU lockout): the failure mode and the
  cloud-console recovery are documented in
  [`../development/lab-notes.md`](../development/lab-notes.md) gotcha #1 — host MTU must be 1400
  before any container engine, or PMTU blackholes the SSH key exchange and locks out all SSH.
  Recover via `ip link set <iface> mtu 1400` from the provider console.
- **Full/crashed Ceph OSDs** (`bluefs enospc` → OSDs won't boot → CephFS provisioning hangs): the
  non-destructive `bluefs-bdev-expand` recovery is
  [`../development/lab-notes.md`](../development/lab-notes.md) gotcha #26.

**Planned** (added as the components they cover land):

- `ceph-recovery.md` — MON/OSD loss, `size 2` single-node caveats, re-add and rebalance
  (production Rook; the lab uses external MicroCeph — see `../../dev/lab/microceph-setup.sh`).
  The full-OSD case is already covered by lab-notes #26 (above).
