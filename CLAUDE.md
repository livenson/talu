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
   **RESOLVED via external Ceph** (see `dev/lab/microceph-setup.sh`): the udev/`/dev` walls live
   only in *node-side* OSD prep and krbd mapping. Run Ceph OUTSIDE the containers — **MicroCeph on
   the host** (`microceph disk add loop,4G,3`; loop OSDs are first-class there, real udev) — and
   connect via **ceph-csi with the `rbd-nbd` mounter** (userspace; krbd fails because host-created
   `/dev/rbdN` is invisible inside the Talos node — same `/dev` isolation). Validated end-to-end:
   RBD provisioning, VolumeSnapshotClass, **data-verified COW clones**, and **RWX-block**. So the
   no-KVM lab DOES get real storage semantics (snapshot/clone/RWX, migration-shaped volumes) —
   only representative migration *performance* still wants nested KVM. Rook-managed OSDs remain
   the thing that doesn't work here; ceph-csi against external Ceph is the vehicle.
   **CAVEAT (see #14):** the Ceph **control-plane** (provision/snapshot/clone objects) is real and
   reliable, but rbd-nbd **data-path mounting** into pods/VMs is INTERMITTENT on the nested node
   (Talos `/dev` has no nbd devices) — so CDI-to-Ceph and Ceph-backed VM disks are not reliable here.
   The COW-clone verification was genuine but relied on a mount that happens to work only sometimes.
11. **Cilium needs `bpf.masquerade: true` on this host — pods have ZERO egress otherwise.** Rocky 10
    is nftables-only, so Cilium's default iptables masquerade silently installs nothing and pods
    can't reach the LAN/internet/host (only the node itself). eBPF masquerade fixes it (and is what
    makes the external Ceph mon reachable from CSI pods). Symptom: `ping 8.8.8.8` from a pod fails
    while image pulls (node-level) still work, so it hides easily.
7. **Rook + loop devices needs `allowLoopDevices: true`** on the operator chart (renders
   `ROOK_CEPH_ALLOW_LOOP_DEVICES=true`). Verify it landed: `helm get manifest rook-ceph | grep ALLOW_LOOP`.
8. **Invalid `cephConfig` keys abort the whole reconcile.** `osd_crush_chooseleaf_type` is a CRUSH
   bootstrap setting, NOT a runtime `ceph config` key — putting it in `cephConfig.global` makes the
   operator's post-mgr step fail and OSD orchestration never starts. Use pool `failureDomain: osd`.
9. **Size the Talos node up.** `talosctl cluster create docker` defaults to 2 GiB / 2 CPU per node —
   too small for Ceph. Pass `--memory-controlplanes 16384 --cpus-controlplanes 6`.
10. **Container engine NOT enabled on boot** during validation (a reboot re-running the engine was
    part of the original lockout). Enable deliberately only once the stack is trusted.

12. **Pod external DNS is broken by default here — CoreDNS forwards to an unusable upstream.**
    Pods reach `8.8.8.8` by IP but name resolution SERVFAILs (`server misbehaving on 10.96.0.10:53`),
    because CoreDNS `forward . /etc/resolv.conf` points at a resolver pods can't use. Fix: patch the
    coredns ConfigMap to `forward . 8.8.8.8 1.1.1.1` and restart. Breaks any pod pulling external
    URLs (CDI HTTP imports, etc.) while node-level image pulls still work — hides easily.
13. **KubeVirt under emulation works; use it right.** Set `spec.configuration.developerConfiguration.useEmulation: true`
    (no `/dev/kvm`). Label VM namespaces `pod-security.kubernetes.io/enforce=privileged` (virt-launcher
    needs NET_ADMIN → violates PSA baseline). **containerDisk VMs boot reliably** (image pulled at node
    level; CirrOS reaches the login prompt under TCG in ~1-2 min) — the dependable VM path here.
    `virtctl console -n <ns> <vm>` needs the namespace flag.
14. **rbd-nbd data-path mounting is INTERMITTENTLY broken on the nested node (Talos `/dev` isolation).**
    Definitive root cause: `/dev/nbd*` exists on the host (16) and inside the ceph-csi nodeplugin (16)
    but the **Talos node's curated `/dev` has ZERO nbd devices** — so rbd-nbd maps the image (nodeplugin
    has nbd devices; a Ceph watcher is taken) but **kubelet, running in the Talos node, can't complete
    the bind-mount** (`failed to find device`), and the orphaned watcher then blocks every retry
    (`rbd image ... is still being used`). A single mount sometimes succeeds (early COW-clone test was
    real but lucky); under sustained use (CDI's prime+scratch, VM disks) it fails. NOTE: an earlier
    guess blamed "two concurrent rbd-nbd volumes" — that was WRONG; even one rbd-nbd volume fails.
    Consequence: **CDI-import-to-Ceph and Ceph-backed VM disks are not reliable on this nested lab.**
    Block volumeMode is separately unusable (kubelet `AttachFileDevice`/losetup fails the same way).
    → Ceph **control-plane** semantics (provision/snapshot/clone objects) are real and validated;
    reliable Ceph **data-path** (mounting into VMs/pods) needs non-nested nodes (nested KVM / real
    hardware, krbd). The reliable VM path on this lab is **containerDisk**.

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
- Manager-agnostic: nothing assumes Waldur (see `docs/integrations/`).
- `make kbuild` must pass (every overlay `kustomize build`s).
