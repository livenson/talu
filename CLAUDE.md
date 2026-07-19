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
Achieved end-to-end: **OIDC login → Pomerium Native SSH → cert-auth into a Cilium-pinned VM sshd**
(Pomerium is the SSH proxy AND the SSH User CA — lands as `talu@ubuntu` via a stock `ssh` client, no
tunnel, no OpenBao, no static password). Also: **kubevirt-manager** VM UI on the same floating IP.
Components + gotchas:
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
18b. **Pomerium is v0.33.0** (bumped from v0.28.0 — a plain image-tag change, ConfigMap kept, rollback =
    tag back). v0.33 adds the **Routes Portal** app-launcher at `/.pomerium/routes` (+ JSON at
    `/.pomerium/api/v1/routes`) — lists each user's authorized apps; **v0.28 only had the User Info
    Dashboard at `/.pomerium/`** (no portal). No OSS admin/management console (that's Pomerium Enterprise).
    After any Pomerium restart, a live `pomerium-cli tcp` tunnel gets one `401`, re-auths via its
    browser-cmd, and reconnects — transient, self-heals; not a regression.
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
    VM's sshd; a Pomerium **`ssh://<vm>`** route (Native SSH, see #21) points at it; a `CiliumNetworkPolicy`
    on the VM namespace allows ingress only from the pomerium namespace — validated: a pod elsewhere is
    DROPPED (Hubble: `Policy denied DROPPED`), Pomerium is allowed. The route NAME is the VM selector — it's
    the middle token users type: `ssh <principal>@<vm>@ssh.<host> -p 23`.
20. **`pomerium-cli tcp` headless:** `--service-account` OR `--browser-cmd <script>` (script curls the
    Dex login for the user) + `--disable-tls-verification`. Run it via `systemd-run` (ssh-backgrounding
    drops); a binary dropped into `/usr/local/bin` needs **`restorecon`** or SELinux denies systemd exec
    (`Permission denied`).
21. **Pomerium Native SSH is the SSH CA (OpenBao REMOVED).** OSS Core v0.30+ (we run v0.33) makes
    Pomerium the SSH proxy AND SSH User CA — users run stock `ssh <principal>@<route>@ssh.<host> -p 23`,
    auth via browser OIDC (Dex), Pomerium issues the cert. No tunnel, no `pomerium-cli`, no OpenBao.
    Config: `ssh_address: ":2222"`, `ssh_user_ca_key_file: /ssh/user_ca`, `ssh_host_key_files:[...]`
    (User CA + 3 host keys in Secret `pomerium-ssh`, mounted `defaultMode 0400`); the User CA **public**
    key is published as ConfigMap `pomerium-user-ca` (what VMs bake into `TrustedUserCAKeys`). SSH routes:
    `from: ssh://<vm>` / `to: ssh://<vm>-ssh.<ns>.svc:22` / `policy:[{allow:{and:[{email:{is:...}}]}}]`.
    **Exposure:** the SG opened **port 23** → host `socat :23 → NodePort 30022 → Pomerium :2222` (before 23
    was opened, SSH squatted on host `:80`; the `pomerium_ssh_host_port` var flips it). The middle token
    (`<route>`) selects the VM — it's the `ssh://<route>` route name, by convention == the VM name.
    **CONNECT FLOW (for debugging):** client offers a key → Pomerium accepts with "partial success"
    (binds the cert to it) → keyboard-interactive prints a device URL `authenticate.<host>/.pomerium/sign_in?user_code=…`
    → user opens it, logs into Dex, clicks **"Verify Sign In"** (a JS SPA — a bare POST to the URL = *deny*).
    **CirrOS/dropbear can't validate certs — use an OpenSSH guest (Ubuntu 24.04 containerDisk).**
    Reliable, in-memory-free (unlike the removed dev-mode OpenBao). Encoded in `identity_pomerium` role +
    `dev/lab/{expose-vm,vm-ssh,gen-vm-manifests}.sh`.
21b. **Guest secrets via cloud-init from a Secret (no OpenBao, no guest agent).** KubeVirt
    `cloudInitNoCloud.secretRef: {name: <vm>-userdata}` (the field is `secretRef`, NOT `userDataSecretRef` —
    strict decoding rejects the latter on v1.8.4) sources the whole cloud-init (CA trust + app secrets like
    `/etc/talu/app.env`) from a Secret whose key is `userdata`. Secrets stay out of the VM manifest; the
    orchestrator writes the labelled Secret. Static/boot-time; dynamic rotation would need a guest agent
    (KubeVirt `accessCredentials`, SSH-keys/passwords only) — out of scope here.
22. **kubevirt-manager on the floating IP.** Web UI for VM lifecycle. Install:
    `kubectl apply -f .../releases/download/<latest>/bundled-<latest>.yaml` (namespace `kubevirt-manager`,
    ClusterRole to drive KubeVirt/CDI, **ClusterIP Service :8080**; PSA warns "restricted" but it runs).
    Exposed on the SAME floating IP as another Pomerium route — `from: https://vms.<host>` →
    `to: http://kubevirt-manager.kubevirt-manager.svc:8080`, `allowed_users: [alice@talu.local]`. No extra
    ports: it rides the existing `socat :443 → NodePort → Pomerium` path; autocert mints the LE cert for
    `vms.<host>` on first hit. Verified: unauth → 302 to Dex; after alice's login the app is served.
    **Two access planes, don't conflate them:** kubevirt-manager's **Console (noVNC/serial)** and
    **LB list** use the app's *ServiceAccount* (behind Pomerium). Getting a *shell* in the guest is the
    Pomerium Native SSH path (#21) — a **terminal flow, not a UI button**.
    - **noVNC console needs `allow_websockets: true` on the Pomerium `vms.*` route** (the console is a
      WebSocket to `subresources.kubevirt.io/.../vnc`); without it the browser says "failed to connect".
      And console drops you at the OS **login prompt** — the CA-hardened Ubuntu VM has no password
      (`lock_passwd`, `PasswordAuthentication no`) so you *can't* log in there by design; console is for
      password/debug VMs (CirrOS `cirros/gocubsgorocks`). Enter the hardened VM via SSH instead.
    - **LB list needs a `CiliumLoadBalancerIPPool`** or every `type: LoadBalancer` stays `<pending>`.
      Added `talu-lab-pool` (blocks `192.168.99.0/24`); Cilium LB-IPAM assigns from it. BUT on this
      NAT'd single-NIC OpenStack VM the LB IP is **not externally routable** (no L2/BGP to the floating
      IP) — reachable in-cluster/on-node only. Practical external access stays **Pomerium routes**, not
      raw LB IPs. (LB IPs matter on real multi-NIC/L2 nodes; here they're control-plane validation.)
23. **`dev/lab/{expose-vm,vm-ssh,gen-vm-manifests}.sh` — the "access a VM" commands (Native SSH).** Not the
    web UI. The target VM is the **middle token** = the `ssh://<vm>` Pomerium route name (== VM selector).
    - `expose-vm.sh <vm> <ns>` creates `<vm>-ssh` Service + `<vm>-ssh-pin` CiliumNetworkPolicy, then
      **re-renders the Pomerium config from every Service labelled `talu.io/ssh-expose=true`** (base HTTP
      routes + the SSH-server block + one `ssh://<vm>` route each — add a VM = add a label). No tunnel.
      **Per-tenant policy:** each route's allow-list comes from the Service's `talu.io/allowed-users`
      **annotation** (emails have `@`, invalid in label values) → `email: in: [...]`. Multi-tenancy
      validated: alice→ubuntu, bob→web1; the PPL engine denies the wrong user both ways (403/200), and
      a `tenant-b` pod is Cilium-DROPPED from `vmfs`'s VM :22.
    - `vm-ssh.sh <vm> [principal]` is a thin wrapper over `ssh <principal>@<vm>@ssh.<domain> -p 23`.
    - `gen-vm-manifests.sh <vm> <ns>` (pure, for an orchestrator) emits the K8s bundle — cloud-init **Secret**
      (CA trust + guest secrets), VM (`secretRef`), Service, pinning — + the `ssh://` route companion.
      `CA_PUBKEY` reads cm `pomerium/pomerium-user-ca`; `GUEST_SECRET` env injects `/etc/talu/app.env`.
    **Productionization** (see `components/platform/access/`): the tenant chart generates the per-VM
    objects (cloud-init Secret, Service, pinning, `ssh://` route), stamped `talu.io/project-uuid`,
    Flux-reconciled. **Kyverno = enforce invariants, NOT generate** (can't edit the Pomerium config blob).

## Component versions (audited 2026-07-18; OpenBao removed — Pomerium is the SSH CA now)
All on latest stable:
K8s v1.36.2 · Talos v1.13.6 · **Cilium v1.19.6** · **cert-manager v1.21.0** · KubeVirt v1.8.4 ·
CDI v1.65.0 · ceph-csi 3.17.0 · **Dex v2.45.1** · **Pomerium v0.33.0** (Native SSH) · kubevirt-manager 1.5.4 ·
**local-path v0.0.36** · **external-snapshotter v8.6.0** · MicroCeph 19.2.3 (squid).
24. **Cilium helm upgrade: DON'T use `--reuse-values` across a minor bump.** 1.18→1.19 fails with
    `standaloneDnsProxy.enabled: nil pointer` — `--reuse-values` drops the chart's NEW default subtrees.
    Fix: `helm get values cilium -n kube-system -o yaml > v.yaml; helm upgrade cilium cilium/cilium
    --version <x> -n kube-system -f v.yaml` (chart defaults fill new keys; user values overlay). The
    failed upgrade is atomic (stayed on 1.18.1, no partial state). Values that MUST survive: `MTU: 1300`,
    `bpf.masquerade: true`, `kubeProxyReplacement: true`, `k8sServiceHost: localhost`/`Port: 7445`.
    Post-bump validation battery (all passed): pod egress (ping 8.8.8.8), external DNS, **large-payload**
    (577KB HTTPS + 1200B DF ping — NOT `-s 1400 -M do`, that exceeds the 1300 MTU and fails *locally*,
    a test artifact not a blackhole), LB-IPAM still assigns, and the OIDC+SSH-cert acceptance path.
    Cilium 1.19 value for Talu: **multi-pool IPAM went Beta→Stable** (tier-1 per-tenant IPs),
    interface-based BGP advert + source-IP override (production VM LoadBalancer IPs), subnet-scoped
    masquerade, wildcard-subdomain FQDN policy. Caution: `CiliumBGPPeeringPolicy` v1 removed (v2 only —
    N/A here, no BGP); LB-IPAM/BGP may need action on upgrade (our `CiliumLoadBalancerIPPool` v2 survived).
25. **HelmRelease-per-tenant (Flux) — VALIDATED end-to-end. The blockers were NOT resources.** A tenant
    is cheap (one small VM); the manual `helm template | kubectl apply` always worked because it never
    used in-cluster controller↔controller networking. Flux failed for two real, specific reasons — don't
    misattribute controller-plumbing/CNI/chart bugs to "the node is too small":
    - **THE chart bug (root cause of the install failure):** the Pomerium User CA pubkey read from cm
      `pomerium-user-ca` has a **trailing newline**; injected into `content: "{{ .sshUserCaPubKey }}"` it
      makes a double-quoted YAML scalar span two lines → `MalformedYAMLError: could not find expected ':'`.
      Local `helm template` MISSED it because `$(kubectl ...)` strips the newline, but Flux `valuesFrom`
      injects the cm value verbatim. Fix: `content: {{ .sshUserCaPubKey | trim | quote }}` (any value from
      a ConfigMap/Secret injected into YAML needs `trim`/`quote`). After the fix: **HR Ready=True, app1
      Running** — full bundle (Secret/VM/Service/pinning/sg CNP/quota/RBAC) rendered by Flux.
    - **Why helm-controller couldn't fetch the chart at first:** `source-controller`'s readiness probe
      false-negatived (kubelet→pod-IP probe times out on the nested CNI though the app serves fine
      internally) → the NotReady pod is **dropped from its Service endpoints** → helm-controller GET to
      `source-controller.svc` had **zero backends → "no route to host."** Not resources — an endpoints/
      networking chain. Workaround on the flaky lab: drop/loosen the readiness probe so it stays in
      endpoints. Also: after re-pushing a fixed chart, **delete+recreate the HelmRelease** (a stuck failed
      install keeps retrying the OLD cached artifact digest even after the OCIRepository updates).
    Earlier (separate, real) wall: **Podman default `--pids-limit=2048`** caps the Talos-in-Podman node
    (whole stack + VMs share it); at the cap new threads fail (`cilium-cni ... failed to create new OS
    thread, errno=11 EAGAIN`). Fix live: `sudo podman update --pids-limit -1 talu-lab-controlplane-1`;
    encode at node-create time. And the **in-cluster registry NodePort is unreachable from the host**
    (HTTP 000) — push charts from **inside** the cluster (`helm push oci://registry.flux-system.svc:5000
    --plain-http`). See `components/tenancy/flux/README.md`.

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
