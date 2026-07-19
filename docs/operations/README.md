# Operations & runbooks

Runbooks for the things the cluster cannot rebuild itself from — the out-of-cluster survival
kit — and for single-node incidents.

**Available today:**

- **Host lockout recovery** (the Docker/network/MTU lockout): the failure mode and the
  cloud-console recovery are documented in
  [`../development/lab-notes.md`](../development/lab-notes.md) gotcha #1 — host MTU must be 1400
  before any container engine, or PMTU blackholes the SSH key exchange and locks out all SSH.
  Recover via `ip link set <iface> mtu 1400` from the provider console.

**Planned** (added as the components they cover land):

- `etcd-restore.md` — restore Talos/etcd from a snapshot into a scratch node (test it — an
  untested backup is a hypothesis).
- `ceph-recovery.md` — MON/OSD loss, `size 2` single-node caveats, re-add and rebalance
  (production Rook; the lab uses external MicroCeph — see `../../dev/lab/microceph-setup.sh`).
