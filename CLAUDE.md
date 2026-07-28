# CLAUDE.md — working notes for AI-assisted development on Talu

Read `docs/architecture/` for what Talu is and why. This file is the concise **operating guide** for
the lab. The full gotcha catalog (stable #IDs), the identity & access-plane build, and audited component
versions live in [`docs/development/lab-notes.md`](docs/development/lab-notes.md) — reference it when
you hit a wall. Update whichever file fits when you burn time on a non-obvious issue.

## The lab (no-KVM validation VM)

- Target: `ssh rocky@203.0.113.10` — Rocky Linux 10.1, OpenStack cloud, **no `/dev/kvm`**.
  16 vCPU / 31 GiB / ~96 GiB disk. `env.sh` holds the current target (IP changes on reinstall).
- Engine is **Podman**, not Docker (Rocky-native, daemonless). talosctl's docker provisioner
  drives it via `DOCKER_HOST=unix:///run/podman/podman.sock` (needs `sudo`; socket is root-owned).
- Cluster: `talosctl cluster create docker` (v1.13: it's a subcommand, no `--controlplanes`/`--wait`).
- Operate from the lab host over SSH (kubeconfig at `~/.talu/kubeconfig`, talosconfig at
  `/root/.talos/config`), or from a laptop via `make lab-tunnel` (`dev/lab/tunnel.sh`): it forwards the
  k8s API + zot and — since the talos-docker API is on a random host port — discovers that port from the
  controlplane container, forwards it to `LAB_TALOS_PORT`, and writes a rewritten talosconfig so
  `talosctl` works locally too.

## The physical lab (KVM bare-metal) — the primary perf/validation env

- 4 KVM-capable hosts **compute1–4** (Rocky, libvirt/qemu) running **nested Talos VMs** (3 CP + 1 worker;
  `environments/rocky-phys`, `ansible/phys-cluster.yml`, `phys_*` roles). Access via the gateway:
  `ssh cloud-user@<gw> -p 22|23|24` = compute1|2|3, compute4 over ProxyJump via :24. kubeconfig +
  talosconfig live on the gateway under `/home/cloud-user/talu/talos-phys/` (`sudo talosctl --talosconfig
  …`). Topology/gotchas: memory `talu-phys-lab.md`; perf findings: `docs/architecture/performance-testing.md §9`.
- **It's real KVM, so most VM-lab gotchas below INVERT.** RBD works (Rook-Ceph **block + CephFS**, not
  CephFS-only, and **not** MicroCeph — Rook operator); live migration works; no Podman pids-limit; host
  MTU is **9000 not 1400**. Still nested, so **Tetragon enforce fails** (cgroup-id resolution) even on
  real hardware, and etcd/scheduler/CM metrics need the `cp-patch` args + a node reboot to scrape.
- **Pod network is a dedicated 802.1Q VLAN on bond0, NOT VXLAN** (`talos_overlay.uplink_mode: vlan`,
  VXLAN is the rollback). The host VXLAN capped pod-to-pod at ~3.2 Gbit/s (the Intel 82599 can't GRO
  VXLAN); the VLAN runs at line rate (~9.9). **Never touch `bond0`** (management/SSH path — no console =
  lockout). Node VMs are sized to the hosts (108/78 GiB, 48 vCPU). SSH into VMs is Pomerium Native SSH on
  the provider-forwarded **`:2222`** → `ssh <principal>@<vm>@ssh.<domain> -p 2222`.
- **Managed tenant Kubernetes (KaaS)** is validated here: Cluster API + Kamaji hosted control planes +
  KubeVirt workers. Provision a tenant cluster with `phys_capi` (once) + `phys_kaas_tenant`
  (`--tags kaas-tenant`, per-tenant vars). Design + resilience results: `docs/architecture/kaas.md`,
  `docs/development/kaas-test-{plan,results}.md`; the values-file chart is
  `components/tenancy/cluster-chart/`. Default is per-tenant etcd on local-path (~50× lower fsync than
  the shared RBD default). `sudo talosctl` needs the FULL path `/usr/local/bin/talosctl` (secure_path).

## Workflow

- `make lab-push` → rsync repo + run `bootstrap/rocky/bootstrap.sh` (Stage 0).
- `make up` → `dev/lab/remote-up.sh`: creates the Talos/Podman cluster (cni=none, loop OSDs,
  16 GiB node), writes `~/.talu/kubeconfig`.
- Then Cilium (helm), then the stack. See `docs/development/validation-plan.md`.

## Critical gotchas (full catalog + access plane + versions in docs/development/lab-notes.md)

Know these before touching the lab — they lock you out or cost hours. These are the **no-KVM VM lab**
gotchas; several INVERT on the physical lab (see that section above — RBD/Rook works, MTU 9000, no
pids-limit). The full catalog (#1–#40) (stable #IDs, cross-referenced from roles/scripts), the identity
& access-plane build, and audited component versions live in
[`docs/development/lab-notes.md`](docs/development/lab-notes.md).

- **Host MTU 1400 BEFORE any container engine** — else PMTU blackholes the SSH key exchange and
  **locks out all SSH** (recover via the cloud console); bootstrap sets it first. (#1)
- **Podman default `--pids-limit=2048` caps the Talos-in-container node** (whole stack + VMs share it) —
  at the cap new threads fail (`errno=11`); `sudo podman update --pids-limit -1 <node-container>`. (#25)
- **Talos enforces PodSecurity `baseline` cluster-wide** — privileged workloads (KubeVirt/VMs) need the
  namespace labelled `pod-security.kubernetes.io/enforce=privileged`. (#5)
- **Cilium needs `bpf.masquerade: true`** on this nftables-only host, or pods get zero egress. (#11)
- **CoreDNS forwards to an unusable upstream** — patch to public forwarders or pod DNS SERVFAILs. (#12)
- **Storage is CephFS, not RBD** — the nested node's `/dev` isolation breaks rbd-nbd; Rook is a wall here. (#14/#15)
- **SSH is Pomerium Native SSH** (Pomerium is the SSH CA) — no OpenBao, no tunnel, no static password. (#21)
- **Tetragon is real-hardware only** — needs kernel BTF + `/sys/kernel/tracing` the nested lab lacks;
  wired into `example` only, omitted from `rocky-sandbox`. Kyverno runs anywhere (Audit-first). (#38/#39)
- **`route-sync` owns the live Pomerium routes** — it re-renders the whole `pomerium-config` blob every
  2 min, so it (not the ansible role) decides the domain. A 404 on *every* host = domain mismatch; both
  writers read `lab_domain` via the `talu-platform` ConfigMap. (#40)

## Debugging discipline (learned the hard way)
- **`kubectl describe <obj>` first.** For a stuck DataVolume/PVC/pod, `kubectl describe` shows the
  controller events (the real error) immediately — far faster than polling `.status.phase` and
  grepping logs separately. Reach for describe on the failing object before anything else.

- **Don't poll with long dumb sleeps.** A `for i in $(seq 1 20); do ...; sleep 15; done` that prints
  "0 0 0" hides the real error for minutes. Instead: read the **controller/operator logs** on the
  first failure (`kubectl -n <ns> logs deploy/<operator> | grep -iE 'error|fail|reconcile'`), check
  the CR `.status.message`, and use `kubectl wait --timeout=Ns`. Surface the latest error line every
  tick and break early on a repeating error.
- For storage specifically: Ceph here is **MicroCeph** (a host snap), not Rook — there is no operator,
  no `osd-prepare` Job, no OSD Deployments to read. Debug the two layers separately: the Ceph cluster on
  the host (`microceph.ceph status`/`health`, `snap logs microceph`; full-OSD recovery is lab-notes #26),
  and the K8s consumer (`ceph-csi-cephfs` provisioner/nodeplugin pods). A PVC stuck Pending →
  `kubectl describe pvc` then the `ceph-csi-cephfs-provisioner` logs, not any operator.

## Repo conventions

- `components/` = the product (don't edit to adopt). `environments/<env>/` = values only.
- Orchestrator-agnostic: nothing assumes a specific orchestrator (see `docs/integrations/`).
- `make kbuild` must pass (every overlay `kustomize build`s).
