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

## Workflow

- `make lab-push` → rsync repo + run `bootstrap/rocky/bootstrap.sh` (Stage 0).
- `make up` → `dev/lab/remote-up.sh`: creates the Talos/Podman cluster (cni=none, loop OSDs,
  16 GiB node), writes `~/.talu/kubeconfig`.
- Then Cilium (helm), then the stack. See `docs/development/validation-plan.md`.

## Critical gotchas (full catalog + access plane + versions in docs/development/lab-notes.md)

Know these before touching the lab — they lock you out or cost hours. The full catalog (#1–#37)
(stable #IDs, cross-referenced from roles/scripts), the identity & access-plane build, and audited
component versions live in [`docs/development/lab-notes.md`](docs/development/lab-notes.md).

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

## Debugging discipline (learned the hard way)
- **`kubectl describe <obj>` first.** For a stuck DataVolume/PVC/pod, `kubectl describe` shows the
  controller events (the real error) immediately — far faster than polling `.status.phase` and
  grepping logs separately. Reach for describe on the failing object before anything else.

- **Don't poll with long dumb sleeps.** A `for i in $(seq 1 20); do ...; sleep 15; done` that prints
  "0 0 0" hides the real error for minutes. Instead: read the **controller/operator logs** on the
  first failure (`kubectl -n <ns> logs deploy/<operator> | grep -iE 'error|fail|reconcile'`), check
  the CR `.status.message`, and use `kubectl wait --timeout=Ns`. Surface the latest error line every
  tick and break early on a repeating error.
- For Ceph specifically: the chain is operator → mon → mgr → `osd-prepare` **Job** → `osd` Deployments.
  If there are no `osd-prepare` pods, the operator hasn't reached OSD orchestration — read operator
  logs, not OSD pods. Read the osd-prepare pod log for per-device decisions.

## Repo conventions

- `components/` = the product (don't edit to adopt). `environments/<env>/` = values only.
- Orchestrator-agnostic: nothing assumes a specific orchestrator (see `docs/integrations/`).
- `make kbuild` must pass (every overlay `kustomize build`s).
