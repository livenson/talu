# backup

**Responsibility:** tier-3 backup & DR — **Velero** (Kubernetes objects) plus the **node-agent**
(kopia file-system backup of volume **data**), writing to a **Garage** S3 bucket.

Tiers 1 and 2 need no component: `talosctl etcd snapshot` is built into Talos and
`VirtualMachineSnapshot` into KubeVirt. The full three-tier model, the backup/restore sequence
diagrams, and the validated round-trips are in
[`docs/operations/backup-restore.md`](../../../docs/operations/backup-restore.md).

## What's in here

- **`namespace.yaml`** — `velero` (PSA **privileged**: the node-agent mounts `/var/lib/kubelet/*`
  hostPaths, and Talos enforces `baseline` cluster-wide — without the label the DaemonSet schedules
  **0 pods** and no volume data is ever backed up) and `garage` (left at `baseline`; it needs no
  host access).
- **`garage.yaml`** — the S3 target: `ConfigMap` (`garage.toml`), `PersistentVolumeClaim`,
  `Deployment` (`dxflrs/garage:v2.3.0`), `Service` (3900 S3 / 3903 admin).
- **`servicemonitors.yaml`** — scrape Velero (`:8085`) and Garage (`:3903`). The `talu:backup_*`
  recording rules, the kube-state-metrics CustomResourceState that yields **true per-tenant backup
  size**, and the Backup & DR dashboard live in `components/platform/monitoring/`.
- **`restore-test.yaml`** — the **DR drill**: a weekly, self-contained CronJob that seeds a canary
  namespace, backs it up, restores it into a scratch namespace, and **verifies the data came back**
  (a Completed restore that restored nothing would still be a lie). Success bumps
  `velero_restore_success_total`; `TaluRestoreTestStale`/`TaluRestoreTestFailed` (in the monitoring
  component's `backup-rules.yaml`) alert if the drill stops or fails. Validated on the lab end-to-end.
- **`helmrepository.yaml` / `helmrelease.yaml` / `values.yaml`** — Velero, chart **`12.1.0`**
  (app **`v1.18.1`**), with `velero-plugin-for-aws v1.11.1` and `kubevirt-velero-plugin v0.7.1` as
  plugin initContainers, `deployNodeAgent: true`, and `defaultVolumesToFsBackup: true`.

## Why Garage, and what it costs

MinIO's community edition is **archived** (console pulled from CE May 2025, docs pulled Oct 2025,
`minio/minio` archived read-only in 2026) — no CVE stream, which is disqualifying for a tier that must
stay restorable for years. [Garage](https://garagehq.deuxfleurs.fr/) (Deuxfleurs, AGPLv3, Rust,
~50 MB, 3–6× smaller footprint) is a drop-in for the **stock `velero-plugin-for-aws`** — validated
end-to-end including kopia.

⚠️ **Garage implements no S3 Object Lock**, so backups are **not WORM-immutable** — anyone holding the
credentials can delete them. Mitigate with a tightly-scoped key, an offsite copy, or a second locking
target. Details and the full API-support table:
[`docs/operations/backup-restore.md`](../../../docs/operations/backup-restore.md).

**Do not point this at Ceph/RGW.** A backup target must not depend on the storage it protects — the
`garage-data` PVC deliberately uses a non-Ceph class, and in production Garage should run **outside**
the cluster it backs up.

## Secrets are not in Git

`garage.toml` deliberately omits `rpc_secret` / `admin_token`; Garage reads them from
`GARAGE_RPC_SECRET` / `GARAGE_ADMIN_TOKEN`. Create both Secrets out-of-band:

```sh
kubectl -n garage create secret generic garage-secrets \
  --from-literal=rpc-secret="$(openssl rand -hex 32)" \
  --from-literal=admin-token="$(openssl rand -base64 32)"
```

## Bootstrap (one-time, imperative — kustomize cannot express it)

**Garage stores nothing until a cluster layout is applied.** This is the step that is easy to miss —
without it `garage status` reports `NO ROLE ASSIGNED` and every write fails:

```sh
POD=$(kubectl -n garage get pod -l app=garage -o jsonpath='{.items[0].metadata.name}')
kubectl -n garage exec $POD -- /garage status                              # note the node ID
kubectl -n garage exec $POD -- /garage layout assign -z dc1 -c 50G <NODE_ID>
kubectl -n garage exec $POD -- /garage layout apply --version 1
kubectl -n garage exec $POD -- /garage bucket create velero
kubectl -n garage exec $POD -- /garage key create velero-key               # prints Key ID + Secret
kubectl -n garage exec $POD -- /garage bucket allow --read --write --owner velero --key velero-key
```

Then hand those credentials to Velero (the name must match `credentials.existingSecret` in
`values.yaml`):

```sh
kubectl -n velero create secret generic garage-credentials --from-file=cloud=/dev/stdin <<EOF
[default]
aws_access_key_id=<Key ID>
aws_secret_access_key=<Secret key>
EOF

kubectl -n velero get bsl default        # PHASE must reach Available
```

> **Migrating an existing install?** Delete the kopia repo bound to the old bucket first
> (`kubectl -n velero delete backuprepository --all`) and restart `deploy/velero` + `ds/node-agent`,
> or file-system backup keeps addressing the old backend. See lab-notes #28.

## Deploying

The **HelmRelease is the production/GitOps path** (Flux helm-controller). The rocky-sandbox lab
installed Velero directly with `helm`/manifests instead, because helm-controller is flaky on the
nested node — so the *flows* below are lab-validated while this HelmRelease wiring is **not yet
exercised on the lab**. Treat that as the open gap.

Validated on the lab (with the equivalent direct install): backup `Completed` →
`PodVolumeBackup Completed` (kopia) → **namespace destroyed** → restore `Completed` →
`PodVolumeRestore Completed` → marker file recovered **byte-for-byte on a new PV**.

This is a reusable base — part of `components/` (the product). Adopters do **not** edit it;
site-specific values (bucket, endpoint, retention, schedules, storage class) live in
`environments/<site>/`. See `docs/customize/` for the customization boundary.
