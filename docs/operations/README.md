# Operations & runbooks

Runbooks for the things the cluster cannot rebuild itself from (the out-of-cluster survival
kit) and for single-node compromises. To be filled in as components land:

- `openbao-unseal.md` — manual unseal ceremony (pilot); unseal material lives off-cluster.
- `etcd-restore.md` — restore from snapshot into a scratch node (test it — an untested backup
  is a hypothesis).
- `ceph-recovery.md` — MON/OSD loss, `size 2` single-node caveats, re-add and rebalance.
- `recovery.md` — recovering the lab VM after a Docker/network lockout (the cloud console).
