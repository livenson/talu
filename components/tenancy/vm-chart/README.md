# `talu-vm` — one tenant VM

The per-VM half of the tenant API. [`../tenant-chart/`](../tenant-chart/) owns the namespace, quota,
RBAC, network baseline, security-group policies, dashboards and log gateway; **this chart renders one
VM**: its cloud-init `Secret`, the `VirtualMachine`, the ssh `Service` and the `<vm>-ssh-pin`
`CiliumNetworkPolicy`.

## Why VMs are their own object

With `vms` inline in the tenant, *"may add a VM"* is `update` on the tenant — which is also the power
to change the quota, the member list and the security groups. That is not grantable to a self-service
portal. Splitting also removes write contention between concurrent portal actions and gives each VM
its own status. Full reasoning: [`adr-api-layer.md` §10.1](../../../docs/architecture/adr-api-layer.md).

## Sizing

`size:` (preferred) renders a reference to `VirtualMachineClusterInstancetype talu-<size>` from
[`../sizes/`](../sizes/). KubeVirt **rejects** a VM that also sets `domain.cpu`/`domain.resources`, so
a size is enforced rather than advisory — and it is the only way this API can express **vCPU** at all.
`memory:` is the deprecated legacy path (it cannot express vCPU: KubeVirt defaults the guest to 1).
Setting both fails fast in the chart.

## Values a consumer does not write

`projectUuid`, `slug` and `allowedUsers` identify the tenant this VM belongs to; the tenancy role
injects them from `tenant.yaml` (the API server will do the same). `sshUserCaPubKey`, `caTrust.*` and
the image coordinates are operator-owned — see `environments/<site>/vm-defaults.yaml`. Ownership is
machine-readable as `x-talu-owner` on every property of `values.schema.json`.

## Importing a disk (`source: import`) — the DR restore path

`source: import` populates the root disk from a URL via a CDI `DataVolume` instead of cloning the
site's golden-image `DataSource`. It exists so a portable disaster-recovery package can be restored
onto Talu without bypassing the chart — see
[`drim-target.md` §4.1](../../../docs/architecture/drim-target.md). `dataDisks: []` adds non-root
volumes (imported or blank); each is addressable in the guest as `/dev/disk/by-id/virtio-<name>`.

```yaml
source: import
rootDiskSize: 40Gi
restore:
  root: { url: "https://s3.example/pkg/rev-7/disk-0.raw" }
  acknowledgeGuestTrust: true
dataDisks:
  - { name: data, size: 500Gi, url: "https://s3.example/pkg/rev-7/disk-1.raw" }
```

**Prefer a presigned `https://` URL.** CDI's `s3://` source needs `secretRef` naming a Secret *in the
DataVolume's namespace* — that puts DR-bucket credentials in the **tenant's** namespace, where the
tenant can read them. A presigned URL puts nothing there.

Three things this mode does **not** do, each of which is silent:

1. **No signature verification.** `verify-images-cosign.yaml` matches DataVolume *registry* sources
   only, so an imported disk is not checked at all. Integrity is the caller's job (a DRIM package
   carries SHA-256 per artifact in its `index.json`; CDI verifies nothing).
2. **No guest trust.** An imported guest carries the SSH CA trust of wherever it came from. Talu's
   access plane is Pomerium Native SSH, so without `/etc/ssh/talu_ca.pub` + `TrustedUserCAKeys`
   **every human login is rejected** — while the VM runs, the guest agent connects, and health checks
   pass. Cloud-init is still attached but does not re-run on an already-provisioned disk, so the
   chart's trust injection does nothing here. `restore.acknowledgeGuestTrust: true` is the required
   acknowledgement that this is handled out of band; the chart refuses to render without it.
3. **No consumer access.** `restore.*` and the data disks' URLs are `x-talu-owner: operator` — which
   image a VM may boot is site plumbing. That marker is a contract, not an enforcement (a
   hand-written HelmRelease can set anything); the real gate is the typed API, whose `TenantVM`
   projection carries disk *names and sizes* only and cannot express a URL.

### Re-trusting an imported guest

`restore.retrust.enabled: true` addresses (2). It holds the VM at `runStrategy: Halted` and runs a
Job that waits for the import, then rewrites the disk **offline** with `virt-customize` — KubeVirt
exposes no generic guest-exec, so there is no online path. It writes `/etc/ssh/talu_ca.pub` and
`/etc/ssh/sshd_config.d/60-talu-ca.conf` from the injected `sshUserCaPubKey`, and optionally clears
the guest's cached cloud-init state (`resetCloudInit`).

It is a **two-step flow, deliberately**: the Job does not start the VM. Set
`restore.retrust.enabled: false` once it has Completed, and the VM boots. Had the Job patched
`runStrategy` itself, Flux would reconcile it straight back to `Halted` and the two would fight —
whether a VM runs stays a Git decision.

> ⚠️ **Unvalidated on hardware.** Open risks: libguestfs' appliance VM under Talos PSA, and whether
> `resetCloudInit` suffices for a guest whose `datasource_list` excludes NoCloud. Set `forceTcg: true`
> where there is no `/dev/kvm`. **Try the cheap thing first** — a guest whose cached instance-id
> differs from the NoCloud one may simply re-run cloud-init and trust the CA for free.

## Security groups

A VM **declares** its groups (`securityGroups: [web]`), which renders a `talu.io/sg.web` label on the
VMI template; the tenant's `CiliumNetworkPolicy` selects on that label. The tenant chart no longer
lists VM names — it cannot know them now that a VM is a separate object.

## Migrating a pre-split tenant without recreating the VM

The old `talu-tenant` release owns the VM objects, so applying the split naively makes Helm **prune
the `VirtualMachine`** (and with it any `dataVolumeTemplates` disk). Transfer ownership instead:

```sh
OBJS="secret/<vm>-userdata virtualmachine.kubevirt.io/<vm> service/<vm>-ssh ciliumnetworkpolicy.cilium.io/<vm>-ssh-pin"
# 1. protect them from the outgoing release's prune
for o in $OBJS; do kubectl -n <slug> annotate $o helm.sh/resource-policy=keep --overwrite; done
# 2. hand them to the incoming release so it adopts rather than creates
for o in $OBJS; do
  kubectl -n <slug> annotate $o meta.helm.sh/release-name=<slug>-<vm> --overwrite
  kubectl -n <slug> annotate $o meta.helm.sh/release-namespace=tenants --overwrite
done
# 3. apply both HelmReleases, then drop the migration-only annotation
for o in $OBJS; do kubectl -n <slug> annotate $o helm.sh/resource-policy- ; done
```

Validated on `rocky-phys`: both releases went `Ready=True` and the running VMI kept its **uid and
start timestamp** — it was never recreated or restarted.
