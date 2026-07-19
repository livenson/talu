# local-path

**Responsibility:** local-path-provisioner — CDI scratch + bootstrap PVCs.

**Upstream:** <https://github.com/rancher/local-path-provisioner>.

**Pilot/prod:** never the default StorageClass (ceph-block is). Install from the upstream
manifest (`rancher/local-path-provisioner .../deploy/local-path-storage.yaml`); its helper
pods use hostPath, so label the `local-path-storage` namespace
`pod-security.kubernetes.io/enforce=privileged`.

**rocky-sandbox deviation (documented):** with Rook Ceph unavailable on the no-KVM lab
(see `docs/development/lab-notes.md` #6), local-path is the **default** StorageClass here so platform PVCs
(Keycloak, zot) bind. This is RWO Filesystem only — no snapshots/clones/RWX/live
migration. Those are validated on a nested-KVM/QEMU environment, not here.
