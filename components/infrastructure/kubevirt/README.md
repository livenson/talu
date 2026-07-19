# kubevirt

**Responsibility:** KubeVirt operator + CR — VM lifecycle, live migration, hotplug (feature-gated).

**Upstream:** [KubeVirt user guide](https://kubevirt.io/user-guide/) · [live migration](https://kubevirt.io/user-guide/compute/live_migration/) · [cloud-init `secretRef`](https://kubevirt.io/user-guide/user_workloads/startup_scripts/).

Install the operator + CR from the KubeVirt release; the CR carries environment values.

**rocky-sandbox (validated):** no `/dev/kvm`, so the KubeVirt CR sets
`spec.configuration.developerConfiguration.useEmulation: true` (QEMU TCG). VM namespaces must be
labeled `pod-security.kubernetes.io/enforce=privileged` (virt-launcher needs NET_ADMIN → violates
PSA baseline). Validated: a CirrOS **containerDisk** VM boots under TCG and reaches the serial-console
login prompt (`virtctl console -n <ns> <vm>`). See `docs/development/lab-notes.md` #13–14 for storage caveats
(Filesystem-mode disks only; containerDisk is the reliable path — CDI-import-to-Ceph is flaky on the
nested node). Sandbox CR:

```yaml
apiVersion: kubevirt.io/v1
kind: KubeVirt
metadata: {name: kubevirt, namespace: kubevirt}
spec:
  configuration:
    developerConfiguration:
      useEmulation: true                 # rocky-sandbox only; real hardware uses KVM
      featureGates: [Snapshot, HotplugVolumes]
```
