# Talu install — Ansible

Idempotent installation of the Talu **no-KVM lab** (Rocky 10, OpenStack), encoding the
validated procedure and every gotcha from `../CLAUDE.md`. Replaces the ad-hoc shell steps;
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
| `identity_pomerium` | IAP **+ Native SSH proxy/CA** (OIDC→Dex, autocert LE, hostAlias, NodePort + host `socat`, :23) | #17,#18,#18b,#21 |

Stage 6 roles (tag `stage6`) carry `lab_domain` (derived from `lab_floating_ip`) so they retarget
on VM reinstall. Per-VM SSH routes are layered by `dev/lab/expose-vm.sh` / `gen-vm-manifests.sh`
(or the tenant chart), not the base `identity_pomerium` role.

## Not covered (deliberate)
Tenant workloads and RBD block storage (unreliable on the nested node — CephFS is the storage path
here; production on real nodes/KVM uses Rook RBD).
