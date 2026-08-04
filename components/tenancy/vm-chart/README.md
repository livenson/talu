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
