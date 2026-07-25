# Talu install — Ansible

Idempotent installation of the Talu **no-KVM lab** (Rocky 10, OpenStack), encoding the
validated procedure and every gotcha from `../docs/development/lab-notes.md`. Replaces the ad-hoc shell steps;
the `dev/lab/*.sh` scripts remain as reference for what each role does.

## Prerequisites (control node = your laptop)
- `ansible` (core) + SSH access to the lab (`inventory.ini`, mirrors `env.sh`).
- Collections: `ansible-galaxy collection install -r requirements.yml` (`kubernetes.core`).
- macOS control node: prefix runs with `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` (fork() crash).

## Run
```sh
cd ansible
ansible-playbook site.yml                 # full install
ansible-playbook site.yml --tags storage  # just CephFS/ceph-csi
ansible-playbook site.yml --tags bootstrap,cluster,cilium   # base cluster only
ansible-playbook site.yml --tags stage6   # identity & access plane only
```
Idempotent: a second full run reports `changed=0` (validated).

## Roles (run in this order by `site.yml`)
| Role | Does | Key gotchas encoded |
|---|---|---|
| `host_bootstrap` | MTU-1400-first, Podman, kernel-modules (vault), sysctls, tooling | #1 lockout, #3 modules, #4 ip_forward |
| `talos_cluster` | `talosctl cluster create docker` on Podman, cni=none, 16 GiB node | podman socket, backgrounded create |
| `cilium` | CNI: kube-proxy replacement, KubePrism, **bpf.masquerade**, MTU 1300 | #11 no-egress |
| `cluster_dns` | CoreDNS → public forwarders | #12 pod DNS |
| `core_services` | local-path (default SC) + cert-manager internal CA | PSA privileged |
| `storage_ceph` | MicroCeph + **CephFS RWX** + ceph-csi-cephfs + snapshotter | #14 RBD unreliable, #15 CephFS + secret adminID/adminKey |
| `kubevirt` | KubeVirt (`useEmulation`) + CDI, scratch→local-path | #13 emulation/PSA |
| `identity_dex` | tiny OIDC IdP (issuer/clients/static user) | #16 Dex-not-Keycloak |
| `kubevirt_manager` | VM web UI bundle (route via Pomerium) | #22 |
| `identity_pomerium` | IAP **+ Native SSH proxy/CA** (OIDC→Dex, autocert LE, hostAlias, NodePort + host `socat`, :23) + metrics `:9902` | #17,#18,#18b,#21 |
| `monitoring` (tag `monitoring`/`obs`) | kube-prometheus-stack (**Prometheus + Alertmanager**) + Perses operator + all operator dashboards (incl. alerts/certs/alert-ops) + `talu:tenant_*`/`talu:backup_*` rules + cert-manager/other ServiceMonitors + alert rules; webhook wired from `alerting_webhook_url` | Perses (not Grafana) is the dashboard layer; Alertmanager null receiver by default |
| `backup` (tag `backup`/`dr`) | Velero (+ node-agent kopia fs-backup) → **Garage** S3; idempotent Garage bootstrap (layout/bucket/key), generated secrets; weekly **DR-drill** CronJob | #27 hostPath skipped, #28 Garage/creds-secret name |
| `logging` (tag `logging`/`audit`) | Loki + Grafana Alloy (pod logs via K8s API) + the **Access Audit** view native in Perses (LokiDatasource + LogsTable) | audit = Perses, no Grafana |
| `tenancy` (tag `tenancy`/`tenants`) | **Flux** (source + helm controllers) + in-cluster chart registry + `talu-tenant` OCIRepository + route-sync; renders a **HelmRelease per `environments/<env>/tenants/*.yaml`** | #25 pids-limit, #36 nested-node probes removed, #37 valuesFrom precedence |

Stage 6 roles (tag `stage6`) carry `lab_domain` (derived from `lab_floating_ip`) so they retarget
on VM reinstall — **keep `lab_floating_ip` in sync with the real VM IP** or Dex's issuer domain is
wrong and every Pomerium sign-in 500s (lab-notes #29). Per-VM SSH routes are layered by
`dev/lab/expose-vm.sh` / `gen-vm-manifests.sh` (or the tenant chart), not the base `identity_pomerium`
role. `cilium` installs the prometheus-operator CRDs before Cilium (its ServiceMonitors need them —
lab-notes #30). Ordering: `monitoring` before `backup`/`logging` (they add Perses CRs to the Perses
server it stands up).

## Not covered (deliberate)
RBD block storage (unreliable on the nested node — CephFS is the storage path here; production on real
nodes/KVM uses Rook RBD). Tenant *workloads* are now covered by the `tenancy` role (Flux renders a
HelmRelease per tenant file); the sample tenants live in `environments/<env>/tenants/`.

---

# Physical lab — `phys-phase0.yml`

A second, independent target: **KVM-capable bare metal** (inventory group `phys`). Everything above
is the no-KVM VM lab and does not apply here — in particular `group_vars/all.yml` sets
`primary_iface_mtu: 1400`, which must **never** be applied to these hosts (their LAN is jumbo 9000,
and lowering MTU on a host with no console is the lab-notes #1 failure mode with no recovery path).
`group_vars/phys.yml` holds the hardware-side overrides; the role never touches MTU.

This is **Phase 0 only** — host prerequisites, so that a cluster built later isn't debugging the
host. Talos/cluster/storage roles for hardware come in Phase 1.

```sh
ansible-playbook phys-phase0.yml                      # apply (no reboot)
ansible-playbook phys-phase0.yml --check --diff       # dry run
ansible-playbook phys-phase0.yml --tags verify        # readiness check only, changes nothing
ansible-playbook phys-phase0.yml -e phys_reboot=true  # apply + reboot, one host at a time
```

`serial: 1` — never both sleds mid-change, never both rebooting.

| What `phys_host_prep` fixes | Why |
|---|---|
| **chrony** → reachable sources (`10.8.0.10`, `10.3.0.10`, pool fallback) and blocks until synced | The image ships `server 10.0.7.100`, unreachable from both sleds (`Reach 0`, ref time = epoch). etcd, Ceph and every TLS/OIDC flow need a synced clock |
| **resolv.conf** owned by ansible (NM `dns=none`), internal resolvers first | `getaddrinfo()` stalled a flat 5.02 s per call with 8.8.8.8 first; the internal resolvers answer A **and** AAAA in <10 ms |
| **Stock kernel** as the grub default | Both sleds boot `…x86_64+debug`; a debug build invalidates every perf number, which is the reason for this hardware. The stock kernel is already installed (grubby index 1) — this is a default-entry change, not an install |
| **`intel_iommu=on iommu=pt`** on all entries + `/etc/default/grub` | 0 IOMMU groups today → no VFIO/SR-IOV passthrough into VMs (the NICs expose 63 VFs/port) |
| **tuned** `virtual-host` | KVM-host profile; Phase 1 runs Talos as KVM guests |
| `/etc/hosts` peer entries, base tools (incl. `ipmitool` — in-band KCS works even though the BMC LAN doesn't) | groundwork for Phase 1 |

**Reported, not fixed** (provider-owned): egress is filtered asymmetrically per host — one sled
reaches `registry.k8s.io` 3/3 while the other times out 3/3. The verify step prints a per-endpoint
reachability line and warns; set `phys_require_registry_egress=true` to make it fatal. The fix is a
provider change or a pull-through mirror (zot is already in the stack).

**Not in scope**: disk layout (blocked on the extra hardware), firewalld/SELinux (Phase 1 owns the
port list), MTU.

> ⚠ **Reboot has no safety net.** The BMC network (`10.9.0.0/16`) is not reachable from these hosts
> and only the two forwarded SSH ports are open inbound, so a host that fails to boot needs the
> provider (they run MAAS — note the `maas` BMC user). `phys_reboot` defaults to `false`; the role
> verifies the stock **and** rescue grub entries exist before it changes the default, and reports a
> pending reboot on every subsequent run until the host actually comes up on the new kernel.

---

# Physical lab — pull-through registry mirror (`phys-registry-mirror.yml`)

The physical lab's WAN egress is **flaky and time-varying**: every host intermittently times out to
`registry.k8s.io` / `ghcr.io` / `quay.io` / `docker.io` / `factory.talos.dev`, but retries converge
(measured 4–8 / 8 first-try per registry). Rather than fight it per node, the mirror caches once and
serves the cluster over the reliable 9000 LAN.

```sh
ansible-playbook phys-registry-mirror.yml
```

`phys_registry_mirror` runs on the `[mirror]` host (compute1) and stands up one stock `registry:2`
pull-through cache per upstream (podman quadlets, ports 5000–5006), cache on local disk (407 GB
free), firewalld-restricted to the LAN ranges. It pre-pulls `registry:2` with retry (the image
itself lives on flaky docker.io), proves each cache with a live manifest pull, and writes a Talos
machineconfig patch (`~/talu/talos-registry-mirror.patch.yaml`) mapping every registry host to its
cache endpoint — apply it to each node so containerd pulls via the LAN. Validated: a cross-node pull
caches on first hit (~3.5 s WAN) and serves the second in ~0.2 s.

Provider-side items this does **not** fix (tracked as tickets): the egress filtering itself, the
missing `:25` forward for compute4, and compute4's dead bond leg (`ens20f0` NO-CARRIER — a fibre/SFP
fault, not software-fixable).
