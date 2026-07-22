# images — golden image pipeline (bootc / image mode)

Golden images are **bootc** (image-mode) OCI images: the OS *is* a container. **Bake capabilities,
inject identity** — the image carries qemu-guest-agent, cloud-init, OpenSSH, and the sshd
`TrustedUserCAKeys` directive; per-tenant identity (the Pomerium CA pubkey, guest secrets) is injected
at **boot** via cloud-init from a Secret, never baked. Because the OS is a container, a running VM
built from the image **self-updates from the registry** (bootc: pull new tag → stage → (soft-)reboot →
activate, with rollback).

- **`<os>/Containerfile`** — the bake (`FROM` an upstream bootc base; `centos-bootc/` is the reference).
  Base image is a build `ARG`, not a baked constant.
- **`build-bootc.sh <dir> <containerdisk-ref>`** — builds the bootc app image, runs `bootc-image-builder`
  → qcow2 (**rootful `--privileged`, no `/dev/kvm` needed** — loopback only), `virt-sparsify`s, and wraps
  it into a KubeVirt **containerDisk**. Runs on any podman host (CI or the lab host), not inside the cluster.

## Delivery (how a build reaches VMs)

CI pushes the signed containerDisk to **zot** (`components/infrastructure/zot/`); a CDI
**`DataImportCron`** (`components/infrastructure/cdi/catalog.yaml`) polls it, imports each new digest, and
rolls a **`managedDataSource`**. Tenant VMs clone from that DataSource (tenant chart `source: dataSource`,
`dataVolumeTemplate → sourceRef`), so **a new VM always boots the latest patched image** with no spec
change; **running VMs self-update via bootc**. Freshness is on the operator dashboard
(`talu:image_outdated` ← `kubevirt_cdi_dataimportcron_outdated`). Lifecycle **sequence diagram** and a
why-bootc comparison: [`../docs/architecture/flows.md`](../docs/architecture/flows.md#golden-image-lifecycle-and-patching);
the decisions behind it: [`../docs/architecture/README.md#design-decisions`](../docs/architecture/README.md#design-decisions).

> Validated on the no-KVM lab: `centos-bootc` built on the host (no nested virt) → containerDisk → zot →
> `DataImportCron` → `DataSource` → a VM boots the self-built image (same- and cross-namespace clone).
> Deferred (Phase 2+): CI pipeline (schedule/CVE trigger, Trivy scan, cosign sign, `testing`→`stable`).
