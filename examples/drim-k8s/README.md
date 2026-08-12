# DRIM `type: k8s` — a worked capture/restore, validated on hardware

A hand-rolled implementation of the two halves of a **DRIM** (`drim/v1alpha1`) Kubernetes component:
capture an infosystem out of one cluster, restore it into a different one. The DR service that would
normally do this does not exist yet, so these scripts *are* the reference for what it has to do.

Validated end-to-end on the physical lab between two Talu KaaS tenant clusters — full write-up and
results in [`docs/architecture/drim-target.md` §10.3](../../docs/architecture/drim-target.md).

| File | What it is |
|---|---|
| `manifest.yaml` | The DRIM manifest produced by the validated run — a real one, not a sketch |
| `capture.sh` | Source side: resource dump + `stripFields` scrub + PV data archive |
| `restore.sh` | Target side: level-0 checksum gate, unpack, StorageClass remap, apply |
| `manifest-hybrid.yaml` | A **hybrid** infosystem — one `vm` + one `k8s` component with a `relationships` DAG, which on Talu means two landing zones |
| `s3.py` | Publish / list / fetch / presign a package against an S3 endpoint (validated against Garage) |

## Running it

```sh
# 1 · capture from the SOURCE cluster
KUBECONFIG=/path/to/source.kubeconfig NS=billing ./capture.sh      # prints the package dir
# 2 · seal the package (index.json + BagIt manifest) — see §11.5 of the doc
# 3 · restore into the TARGET cluster
KUBECONFIG=/path/to/target.kubeconfig PKG=/path/to/pkg/<revision> ./restore.sh
```

## Sharing the package through S3

```sh
export S3_ENDPOINT=http://garage.garage.svc:3900 S3_BUCKET=drim-packages
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=garage
python3 s3.py put  /path/to/pkg/<revision> <revision>   # upload
python3 s3.py ls                                        # sizes + etags
python3 s3.py get  <revision> ./fetched                 # download to a clean dir, then re-verify
python3 s3.py presign <revision>/snapshots/vm/db-primary/disk-0.raw.zst
```

**Hand the VM restore a presigned URL, not credentials.** CDI then fetches the artifact with nothing
sensitive in the tenant namespace. Sign against the endpoint *the importer* will use — the signature
covers the `Host` header, so a URL signed for `127.0.0.1:3900` will not verify from inside the cluster.

## The three things that are easy to get wrong

Each of these was found by the run, not by reading the spec:

1. **`stripFields: [spec.volumeName]` is not enough for a PVC.** The binding *annotations*
   (`pv.kubernetes.io/bind-completed`, `bound-by-controller`, `volume.kubernetes.io/storage-provisioner`
   and its `beta` alias, `selected-node`) must go too. Leave them and the restored claim goes straight
   to **`Lost`** — pods `Pending`, nothing explaining why. lab-notes #49.
2. **A naive include-list captures `kube-root-ca.crt`**, the auto-created ConfigMap holding the
   *source* cluster's CA bundle. Never restore it into another cluster.
3. **Secrets are excluded by design (§7), so the workload will not start until an operator supplies
   them.** That is the `WAITING_INPUT` state, not a bug — `restore.sh` stops at exactly that point.
4. **`metadata.namespace` survives capture too**, pinning every object to the source namespace, so
   `kubectl apply -n <other>` is rejected and no namespace remap is possible. `restore.sh` strips it.

## What the run proved

Source `tenant-a` (StorageClass `kubevirt` → kubevirt-csi → infra Ceph RBD) → target `tenant-dr`
(StorageClass `local-path`), i.e. the profile's `storageClass` remap was exercised, not bypassed.
The restored PV data hashed **identical** to the source (`md5 22795d2c…`), the Deployment reached
2/2, the Service served the restored file, and the source secret value appeared nowhere in the
package.
