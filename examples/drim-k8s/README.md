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

## Running it

```sh
# 1 · capture from the SOURCE cluster
KUBECONFIG=/path/to/source.kubeconfig NS=billing ./capture.sh      # prints the package dir
# 2 · seal the package (index.json + BagIt manifest) — see §11.5 of the doc
# 3 · restore into the TARGET cluster
KUBECONFIG=/path/to/target.kubeconfig PKG=/path/to/pkg/<revision> ./restore.sh
```

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

## What the run proved

Source `tenant-a` (StorageClass `kubevirt` → kubevirt-csi → infra Ceph RBD) → target `tenant-dr`
(StorageClass `local-path`), i.e. the profile's `storageClass` remap was exercised, not bypassed.
The restored PV data hashed **identical** to the source (`md5 22795d2c…`), the Deployment reached
2/2, the Service served the restored file, and the source secret value appeared nowhere in the
package.
