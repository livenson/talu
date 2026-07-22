# Node maintenance & rolling upgrades

Patching a node (Talos, kernel, Kubernetes, Cilium, KubeVirt, Ceph) means **evacuating its VMs first**.
Talu does this with **KubeVirt live migration**: every VM runs with the cluster-default
`evictionStrategy: LiveMigrate` (set in the `kubevirt` role's KubeVirt CR), so draining a node
**migrates** its VMs to another node instead of powering them off. KubeVirt auto-creates a
PodDisruptionBudget per VM and its evacuation controller watches the `kubevirt.io/drain` taint.

**Requirements:** RWX storage (CephFS ✓) and at least one **other schedulable node** to migrate onto.
Only **migratable** VMs move: a `dataSource` VM on CephFS migrates; an ephemeral **`containerDisk`** VM
(local, non-shared disk) can't — it has no migration PDB and will **stall a drain** (the
`TaluVMINonEvictable` alert). Recreate/stop those before maintenance, or accept their downtime.

> **Single-node lab:** the rocky-sandbox is one Talos-in-Podman node, so there's nowhere to migrate to.
> The tooling detects this and **refuses to evacuate** — it drains only non-VM pods and leaves the VMs
> running (never silently powers one off). Live migration is exercised only on real multi-node hardware.

## Take a node out of / back into service

```sh
make node-status                     # nodes + where each VM runs
make node-drain    N=<node>          # cordon → taint → live-migrate VMs off → drain
#   ... do the maintenance ...
make node-uncordon N=<node>          # remove the taint + uncordon
```

`node-drain` waits (up to `WAIT_TIMEOUT`, default 600s) for the node to empty of VMIs, printing active
`VirtualMachineInstanceMigration`s each tick, and **fails loudly rather than force-killing VMs** if
migrations don't complete. Under the hood it's `dev/lab/node-maintenance.sh` (run it directly on the lab
host for the same effect).

## Rolling Talos / Kubernetes upgrade

Order matters: **control-plane first, one node at a time** (never lose etcd quorum), then workers. Each
node is drained (migrating its VMs) before it's upgraded. Versions are pinned in
`ansible/group_vars/all.yml` (`talos_version`, `kubernetes_version`).

```sh
# ALWAYS dry-run first — prints the ordered plan + exact commands, executes nothing:
make talos-upgrade                                   # (CHECK defaults to --check)
# Real run on multi-node hardware:
make talos-upgrade CHECK= TALOS_INSTALLER_IMAGE=ghcr.io/siderolabs/installer:v1.11.2
# Then bump Kubernetes itself (Talos orchestrates it centrally, run once):
make talos-upgrade-k8s CHECK= KUBERNETES_VERSION=v1.34.1
```

`talos-upgrade.sh` stages each upgrade (`talosctl upgrade --stage`), waits for the node to go `Ready`
and etcd to report healthy before touching the next node. On the single-node Podman lab the node
**can't be upgraded in place** — use `--check` there; do the real upgrade on KVM hardware.

## Rollback
Talos keeps the previous install; if a node comes up bad, `talosctl rollback --nodes <ip>` reverts it
to the prior boot. For Kubernetes, pin `kubernetes_version` back and re-run `talos-upgrade-k8s`.

## What to watch (alerts)
`components/platform/monitoring/node-rules.yaml` adds: **TaluNodeNotReady**, **TaluNodeCordonedTooLong**
(forgot to uncordon), **TaluVMINonEvictable** (a VM that *can't* migrate will stall a drain — usually an
RWO volume), **TaluVMIMigrationStuck**. They surface in Prometheus `/alerts` and the dashboards
(Alertmanager is not yet wired — see the monitoring component).
