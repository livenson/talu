# kaas-backup

**Responsibility:** disaster recovery for **KaaS tenant clusters** — the half Velero cannot reach.

A tenant cluster's state lives in its **dedicated `kamaji-etcd`** (see
[`docs/architecture/kaas.md`](../../../docs/architecture/kaas.md)). Velero backs up the management
cluster and VM tenants, but a hosted control plane's etcd is not in that picture — lose it and the
tenant cluster is gone. A tenant's DR artifact is therefore **two** things:

| Artifact | Where it comes from | Where it's defined |
|---|---|---|
| **etcd snapshot** (the control plane) | mgmt-side CronJob, `etcdctl snapshot save` → Garage | **here** — `etcd-snapshot.yaml` |
| **workload + PVC data** | in-tenant Velero (node-agent on the worker VMs) → Garage | `talu-cluster` chart `backup.inTenant` (a velero `HelmChartProxy`) + `garage-lb.yaml` |

The in-tenant half needs Garage reachable from the tenant (`components/platform/backup/garage-lb.yaml`
exposes it on LB-IPAM), a per-tenant bucket, and the creds Secret provisioned in the tenant (SOPS/CRS).

## What's in here

- **`etcd-snapshot.yaml`** — the `kaas-etcd-snapshot` CronJob (+ SA/RBAC/scripts) in `kamaji-system`.
  It follows the **reconciler-CronJob idiom** (`route-sync`/`cluster-sync`): every 15 min a single Job
  pod is **discovery-driven** — it lists every Kamaji `DataStore` of `driver: etcd`, and for each one
  reads the endpoints + client-cert secret refs **from the DataStore CR itself** (so nothing hardcodes
  a tenant name; a new tenant is backed up automatically, a deleted one stops producing snapshots).
  Three ordered stages: **discover** (kubectl) → **snapshot** (`etcdctl snapshot save` + `snapshot
  status` integrity hash) → **upload** (`aws s3 cp` to `s3://kaas-etcd/<datastore>/<ts>.db`, prune to
  the newest `KEEP`). **RPO target: 15 min.**

Freshness/failure are observed by **kube-state-metrics on the CronJob/Job** — no Pushgateway. The
`KaasEtcdSnapshotStale` (last success > 1h) and `KaasEtcdSnapshotFailing` alerts live in
`components/platform/monitoring/kaas-rules.yaml`.

## Bootstrap (one-time, imperative — kustomize cannot express it)

A **dedicated** Garage bucket + scoped key (separate from Velero's, so a leaked etcd-backup key cannot
touch VM backups). On the physical lab the `phys_kaas_backup` role does all of this; by hand:

```sh
POD=$(kubectl -n garage get pod -l app=garage -o jsonpath='{.items[0].metadata.name}')
kubectl -n garage exec $POD -- /garage bucket create kaas-etcd
kubectl -n garage exec $POD -- /garage key create kaas-etcd-key          # prints Key ID + Secret
kubectl -n garage exec $POD -- /garage bucket allow --read --write --owner kaas-etcd --key kaas-etcd-key

kubectl -n kamaji-system create secret generic garage-etcd-credentials --from-file=cloud=/dev/stdin <<EOF
[default]
aws_access_key_id=<Key ID>
aws_secret_access_key=<Secret key>
EOF
```

⚠️ Garage has **no S3 Object Lock** — snapshots are not WORM-immutable (same caveat as Velero's target;
see the backup component). Scope the key tightly and keep an offsite copy for a real DR posture.

## Restore

Two tiers (full runbook + the KT-33/34 integrity + destroy-and-restore drills in
[`docs/development/kaas-test-plan.md`](../../../docs/development/kaas-test-plan.md)):

- **Path A — in-place etcd restore** (RTO ≈ minutes): `etcdctl snapshot restore <ts>.db` into a fresh
  data dir for the tenant's `kamaji-etcd`, re-point the members, then let CAPI re-provision workers.
- **Path B — full rebuild**: re-apply the `talu-cluster` values, then an in-tenant Velero restore of
  workloads + PVC data. Storage/version-portable; use when the snapshot won't load or you're moving
  clusters.

## Deploying

The manifest is the product; site tuning (schedule, `KEEP` retention) belongs in
`environments/<site>/`. Not yet wired into an env overlay — on the physical lab it's applied by
`ansible-playbook phys-stack.yml --tags kaas-backup`.

**Lab-validated 2026-07-30 (KT-33):** discover → snapshot → upload ran green against the shared
`kamaji-etcd` — a 10 MB snapshot + its `status.json` landed in `s3://kaas-etcd/…`. Two fixes came out
of it: the snapshot image is **`bitnamilegacy/etcd:3.5.21`** (Bitnami's 2025 Docker Hub migration
pulled `bitnami/etcd:latest`, and the cluster's own `quay.io/coreos/etcd` is distroless — no shell for
the loop), and the pod is now **restricted-PSA compliant** (kamaji-system warns `restricted`). The
destroy-and-restore round-trip (KT-34) remains the open gap.

This is a reusable base — part of `components/` (the product). Adopters do **not** edit it.
