# Talu install — Ansible

Idempotent installation of the Talu **no-KVM lab** (Rocky 9/10, OpenStack cloud), encoding the
validated procedure and every gotcha from `../CLAUDE.md`. Replaces the ad-hoc shell steps;
the `dev/lab/*.sh` scripts remain as reference for what each role does.

## Prerequisites (control node = your laptop)
- `ansible` (core) + SSH access to the lab (`inventory.ini`, mirrors `env.sh`).
- Optional: `kubernetes.core` collection (`ansible-galaxy collection install kubernetes.core`)
  — the roles fall back to `kubectl`/`helm` shell calls if it's absent.

## Run
```sh
cd ansible
ansible-playbook site.yml                 # full install
ansible-playbook site.yml --tags storage  # just CephFS/ceph-csi
ansible-playbook site.yml --tags bootstrap,cluster,cilium   # base cluster only
```

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

## Not covered (deliberate)
Tenant workloads, the identity/access plane (Stage 6), and RBD block storage (unreliable on
the nested node — CephFS is the storage path here). Production (real nodes/KVM) uses Rook RBD.
