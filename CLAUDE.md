# CLAUDE.md — working notes for AI-assisted development on Talu

Read `docs/architecture/` for what Talu is and why. This file is the **operational** companion:
how to work the lab, and the hard-won gotchas discovered while validating on it. Update it
whenever you burn time on a non-obvious issue.

## The lab (no-KVM validation VM)

- Target: `ssh rocky@203.0.113.10` — Rocky Linux 10.1, OpenStack cloud, **no `/dev/kvm`**.
  16 vCPU / 31 GiB / ~96 GiB disk. `env.sh` holds the current target (IP changes on reinstall).
- Engine is **Podman**, not Docker (Rocky-native, daemonless). talosctl's docker provisioner
  drives it via `DOCKER_HOST=unix:///run/podman/podman.sock` (needs `sudo`; socket is root-owned).
- Cluster: `talosctl cluster create docker` (v1.13: it's a subcommand, no `--controlplanes`/`--wait`).
- Operate from the lab host over SSH (kubeconfig at `~/.talu/kubeconfig`, talosconfig at
  `/root/.talos/config`). Laptop-tunnel workflow is a TODO (talos-docker API is on a random port).

## Workflow

- `make lab-push` → rsync repo + run `bootstrap/rocky9/bootstrap.sh` (Stage 0).
- `make up` → `dev/lab/remote-up.sh`: creates the Talos/Podman cluster (cni=none, loop OSDs,
  16 GiB node), writes `~/.talu/kubeconfig`.
- Then Cilium (helm), then the stack. See `docs/development/rocky9-validation-plan.md`.

## Gotchas & fixes (each cost real time — don't rediscover)

1. **Host MTU must be 1400 BEFORE any container engine starts.** The path carries ~1400-byte
   packets; the NIC defaults to 1500. When Docker/Podman touches forwarding, PMTU discovery
   breaks and large host packets (the SSH key exchange!) blackhole — **locking out all SSH**
   while ping/TCP-connect still work. Symptom = SSH resets during kex for everyone. Recover via
   OpenStack cloud console: `sudo ip link set <iface> mtu 1400`. Bootstrap sets it first, live+persistent.
2. **Rocky 10 is nftables-only** — no legacy `ip_tables`/`xt_addrtype`. (Docker CE needed
   `firewall-backend: nftables`; Podman handles it natively.)
3. **Minimal image ships only `kernel-modules-core`.** The full `kernel-modules` (for the
   *running* kernel) is often gone from the live repo — install it from the Rocky **vault**
   (`dl.rockylinux.org/vault/rocky/$VERSION_ID/BaseOS/...`). **`br_netfilter` is still absent**
   on this kernel — Cilium eBPF doesn't care; flannel/kube-proxy/bridge do.
4. **Docker (if ever used) needs `net.ipv4.ip_forward=1` to even start** — set sysctls before
   the engine, not after (a `set -e` script that starts the engine first aborts before sysctls).
5. **Talos enforces Pod Security `baseline` cluster-wide.** Privileged workloads (Rook, KubeVirt)
   fail with `violates PodSecurity "baseline"` and the pods are silently never created. Fix: label
   the namespace `pod-security.kubernetes.io/enforce=privileged` (+warn/audit). Encode this on any
   privileged component's namespace.
6. **Rook Ceph does NOT work on the no-KVM Talos-in-container lab — confirmed wall.**
   `talosctl get disks` is empty; the container gets no real block device. You can bind-mount a
   host loop device in (`--mount type=bind,source=/dev/loopN,...`; privileged, so the node + a
   privileged pod see `/dev/loopN` and `/sys/block/loopN`). BUT `ceph-volume` then fails with
   *"No udev data could be retrieved for /sys/block/loopN"* and `rook-ceph-osd-prepare` reports
   *"skipping OSD configuration as no devices matched"*. Injecting/binding host `/run/udev` does
   not satisfy pyudev inside the nested container. This is a **documented Rook limitation**, not a
   config error: rook#11353, rook#16958 (same failure on Docker-Desktop/Minikube loop devices);
   Sidero's Rook-on-Talos guide requires **real raw disks** ("osd-prepare will not use loop devices").
   → Storage (Rook) and anything needing snapshot/clone/RWX must be validated on **nested KVM
   (QEMU provisioner, real virtio disks)** or real hardware — exactly the fidelity split the plan
   always called out for the no-KVM tier. For KubeVirt CRD/API validation without Ceph, use
   local-path (RWO Filesystem) — enough to exercise the API surface, not migration/snapshots.
7. **Rook + loop devices needs `allowLoopDevices: true`** on the operator chart (renders
   `ROOK_CEPH_ALLOW_LOOP_DEVICES=true`). Verify it landed: `helm get manifest rook-ceph | grep ALLOW_LOOP`.
8. **Invalid `cephConfig` keys abort the whole reconcile.** `osd_crush_chooseleaf_type` is a CRUSH
   bootstrap setting, NOT a runtime `ceph config` key — putting it in `cephConfig.global` makes the
   operator's post-mgr step fail and OSD orchestration never starts. Use pool `failureDomain: osd`.
9. **Size the Talos node up.** `talosctl cluster create docker` defaults to 2 GiB / 2 CPU per node —
   too small for Ceph. Pass `--memory-controlplanes 16384 --cpus-controlplanes 6`.
10. **Container engine NOT enabled on boot** during validation (a reboot re-running the engine was
    part of the original lockout). Enable deliberately only once the stack is trusted.

## Debugging discipline (learned the hard way)

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
- Manager-agnostic: nothing assumes Waldur (see `docs/integrations/`).
- `make kbuild` must pass (every overlay `kustomize build`s).
