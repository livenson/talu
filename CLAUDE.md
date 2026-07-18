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
    **FIX TO VALIDATE (not yet done):** fresh single rbd-nbd mounts actually succeed; the reliability
    collapse is stale RBD watchers from killed pods + the nbd-device gap. The documented Talos
    workaround (Ceph tracker #22012; Sidero disc. #8557) is a **bind mount of `/dev` with `rshared`
    propagation** into the node so host/dynamic devices reach kubelet. Encoded behind
    `LAB_SHARE_HOST_DEV=1` in `dev/lab/remote-up.sh` (adds `--mount type=bind,source=/dev,target=/dev,bind-propagation=rshared`).
    **VALIDATED (two rebuilds), verdict = partial, not a clean fix:**
    - Whole-`/dev` bind is **shadowed by Talos's own `/dev` remount** — node still sees 0 nbd devices.
    - **Individual `/dev/nbd0..15` binds** get further: rbd-nbd progresses from "failed to *find* device"
      to "failed to *open* device", and **3/3 simple rbd-nbd mounts passed** on a clean cluster.
    - BUT ceph-csi runs rbd-nbd with `--try-netlink`, which **dynamically allocates higher-numbered
      nbd devices (nbd22-24) beyond the bound 0-15** → "failed to open device: /dev/nbd22" → CDI still
      fails. Static binds are defeated by dynamic allocation.
    - A fuller attempt would bind a large nbd range (0-63) AND cap rbd-nbd's allocation to it, or drop
      `--try-netlink` — untested. Bottom line: **reliable Ceph data-path still effectively needs
      non-nested Talos** (real VMs / nested KVM where Talos udevd manages real devices). Talos never
      exposes the dynamic device nodes to kubelet on the docker provisioner.

15. **CephFS WORKS where RBD doesn't — the storage answer for the no-KVM lab.** The `/dev` wall is
    block-device-specific (rbd/krbd/nbd map a `/dev/*` node). CephFS mounts are network **filesystem**
    mounts (kernel `mount -t ceph`, or ceph-fuse via `/dev/fuse`) — no block device, so they work on
    the nested Talos node. Validated: enable CephFS on MicroCeph (`microceph.ceph fs volume create talufs`),
    install **ceph-csi-cephfs** against the external cluster, and an **RWX** PVC mounts across two pods
    (writer→reader verified). Gives RWX Filesystem + snapshots — and RWX Filesystem can back KubeVirt
    disks AND **enable live migration** (RWX is the requirement), which RBD-block couldn't do here.
    GOTCHA: the ceph-csi-cephfs helm chart writes the secret with `userID`/`userKey`, but the driver
    needs **`adminID`/`adminKey`** — create the secret manually with those keys or provisioning fails
    with `rados: ret=-22`. Use a dedicated `client.cephfs` (mon 'allow r', mgr 'allow rw',
    osd 'allow rw tag cephfs *=*', mds 'allow rw').
    Re: **Rook + CephFS** — Rook-managed still needs OSDs on the node (same udev wall); Rook-external
    against MicroCeph would work but is redundant vs plain ceph-csi-cephfs. Use CephFS here; RBD/Rook
    on real nodes (KVM) in production.

## Stage 6 — identity & access plane (validated on the lab)
Achieved end-to-end: **`pomerium-cli tcp` → OIDC login → Pomerium → Cilium-pinned VM sshd** (logged
into the CirrOS VM as `cirros` after alice's OIDC auth). Components + gotchas:
16. **IdP = Dex** (not Keycloak, for the lab). Keycloak 26 fought us: JVM weight, **ephemeral H2 wiped
    on every restart** (needs a PVC or realm-import), user-profile requires firstName/lastName ("Account
    is not fully set up"), and a data-dir permission crash. Dex is a tiny Go OIDC provider, static
    users/groups via ConfigMap, no DB — issuer `https://id.<host>/dex`, `staticPasswords` need a real
    bcrypt hash (`htpasswd -nbBC 10 x <pw>`, then `$2y`→`$2a`). Platform keeps Keycloak/ZITADEL as the
    real-IdP swap (generic OIDC); lab uses Dex. `oidc-group-membership-mapper` gives group claims where
    the IdP supports it (Dex static users don't — gate on email/`allowed_users` for the lab).
17. **Pomerium OIDC loop fix.** Pomerium fetches the IdP discovery from `idp_provider_url` (the EXTERNAL
    url), which it can't reach (floating-IP hairpin) and doesn't trust (self-signed talu-ca). Fix:
    `certificate_authority: <base64 talu-ca>` in config + a **pod `hostAlias`** mapping `id.<host>` and
    `authenticate.<host>` → `127.0.0.1` so Pomerium loops through its own `:443` internally. Browsers
    still resolve the real floating IP via public sslip.io.
18. **Exposing a cluster :443/:80 on the lab floating IP:** the SG allows only 22/80/443. NodePort the
    service (30443/30080) and `systemd-run socat TCP-LISTEN:443 → 10.5.0.2:30443` (kubectl port-forward
    is too fragile; plain `&`-backgrounding over ssh drops the session — **use `systemd-run`**).
    **Real Let's Encrypt certs DO work once :443 is stably exposed** — set Pomerium `autocert: true` +
    `autocert_dir: /data/autocert` (persist on a PVC to survive restarts / avoid re-issuance). LE
    TLS-ALPN-01 validates via the sslip.io name → floating IP → socat → Pomerium. Issued for
    `id/whoami/ssh.203-0-113-10.sslip.io` (issuer Let's Encrypt), so the browser trusts it and
    `--disable-tls-verification` is NOT needed. (The earlier self-signed talu-ca fallback was only
    because :443 wasn't stably exposed yet — and sslip.io shares LE's per-domain rate limit, so it can
    occasionally fail with "too many certs".) With a real cert, drop `certificate_authority` from the
    Pomerium config; the internal OIDC loop trusts LE via system roots (keep the `hostAlias`).
19. **Per-VM SSH exposure + pinning:** a Service (`selector: kubevirt.io/vm: <vm>`, port 22) fronts the
    VM's dropbear; a Pomerium **`tcp+https://ssh.<host>:22`** route tunnels to it; a `CiliumNetworkPolicy`
    on the VM namespace allows ingress only from the pomerium namespace — validated: a pod elsewhere is
    DROPPED (Hubble: `Policy denied DROPPED`), Pomerium is allowed.
20. **`pomerium-cli tcp` headless:** `--service-account` OR `--browser-cmd <script>` (script curls the
    Dex login for the user) + `--disable-tls-verification`. Run it via `systemd-run` (ssh-backgrounding
    drops); a binary dropped into `/usr/local/bin` needs **`restorecon`** or SELinux denies systemd exec
    (`Permission denied`). Still TODO: OpenBao SSH CA for short-lived certs (replaces the VM password).

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
