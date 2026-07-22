# Talu lab engineering notes

The detailed, hard-won record from validating Talu on the no-KVM lab: the full **gotcha catalog**
(stable #IDs, cross-referenced from roles/scripts/docs), the **Stage 6** access-plane build, and the
**audited component versions**. Reference companion to [`../../CLAUDE.md`](../../CLAUDE.md) (the concise
operating guide) — this loads on demand, not every session.

## Gotchas & fixes (each cost real time — don't rediscover)

> Numbers are **stable IDs**, not a sequence — they're cross-referenced from roles/scripts/docs, so
> new ones append and old ones never renumber (hence #11 sitting mid-list). #6–#9 are **historical
> Rook findings** (Rook is not used — CephFS #15 is the storage path); #20 is **superseded** by #21.

1. **Host MTU must be 1400 BEFORE any container engine starts.** The path carries ~1400-byte
   packets; the NIC defaults to 1500. When Docker/Podman touches forwarding, PMTU discovery
   breaks and large host packets (the SSH key exchange!) blackhole — **locking out all SSH**
   while ping/TCP-connect still work. Symptom = SSH resets during kex for everyone. Recover via
   the cloud console: `sudo ip link set <iface> mtu 1400`. Bootstrap sets it first, live+persistent.
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
20. **SUPERSEDED by #21 (Native SSH) — kept for reference / other TCP tunnels.** `pomerium-cli tcp`
    headless: `--service-account` OR `--browser-cmd <script>` (script curls the Dex login) +
    `--disable-tls-verification`; run via `systemd-run` (ssh-backgrounding drops); a binary in
    `/usr/local/bin` needs **`restorecon`** or SELinux denies systemd exec. VM SSH no longer uses this —
    Pomerium Native SSH (#21) replaced the tunnel — but the pattern still applies to any `tcp+https` route.
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

## A deployed lab — real output & SSH access

Verbatim output from a live single-node lab running the full stack (Talos-in-Podman, one tenant
`acme` with a running VM `app1`). Nothing here is edited **except** the floating IP/domain, shown as
the RFC-5737 documentation address `203.0.113.10` / `203-0-113-10.sslip.io` (the real lab uses its
own). `AGE` columns are a point-in-time snapshot.

**The cluster (one node, nested):**

```console
$ kubectl get nodes -o wide
NAME                      STATUS   ROLES           AGE   VERSION   INTERNAL-IP   EXTERNAL-IP   OS-IMAGE          KERNEL-VERSION                          CONTAINER-RUNTIME
talu-lab-controlplane-1   Ready    control-plane   22h   v1.36.2   10.5.0.2      <none>        Talos (v1.13.6)   6.12.0-124.52.1.el10_1.x86_64 (amd64)   containerd://2.2.5
```

**A tenant and its VM** — a tenant is a `HelmRelease`; deleting it garbage-collects the whole
bundle. `HelmRelease.status` is the single object an orchestrator watches:

```console
$ kubectl get helmrelease -n tenants acme
NAME   AGE     READY   STATUS
acme   6h25m   True    Helm install succeeded for release tenants/acme.v1 with chart talu-tenant@0.1.0+44ebf791bc2a

$ kubectl get ns acme --show-labels
NAME   STATUS   AGE     LABELS
acme   Active   6h25m   app.kubernetes.io/managed-by=Helm,helm.toolkit.fluxcd.io/name=acme,helm.toolkit.fluxcd.io/namespace=tenants,kubernetes.io/metadata.name=acme,pod-security.kubernetes.io/audit=privileged,pod-security.kubernetes.io/enforce=privileged,pod-security.kubernetes.io/warn=privileged,talu.io/project-uuid=aaaaaaaa-1111-2222-3333-444444444444,talu.io/slug=acme

$ kubectl get vm,vmi -n acme
NAME                              AGE     STATUS    READY
virtualmachine.kubevirt.io/app1   6h25m   Running   True

NAME                                      AGE     PHASE     IP             NODENAME                  READY
virtualmachineinstance.kubevirt.io/app1   6h25m   Running   10.244.0.213   talu-lab-controlplane-1   True
```

### How SSH access happens (Pomerium Native SSH)

There is no public `:22`, no tunnel, and no static VM password. A user runs stock `ssh`; Pomerium
is both the SSH proxy **and** the SSH User CA that mints a short-lived certificate after OIDC login:

```console
$ vm-ssh.sh app1 talu          # thin wrapper -> ssh talu@app1@ssh.203-0-113-10.sslip.io -p 23
Pomerium native SSH -> talu@app1@ssh.203-0-113-10.sslip.io:23
(first connect opens a browser URL for OIDC login; approve 'Verify Sign In')
```

The SSH user field carries two tokens — `<principal>@<vm>` — where `<principal>` is the login user
inside the guest (`talu`) and `<vm>` selects the Pomerium `ssh://` route. The path:

```
ssh talu@app1@ssh.203-0-113-10.sslip.io -p 23
   │   host :23  —  socat TCP-LISTEN:23,fork,reuseaddr  TCP:10.5.0.2:30022
   ▼
   NodePort 30022  →  Service pomerium (:2222)
   ▼
   Pomerium SSH proxy (ssh_address ":2222")
   │   1st connect → browser OIDC device flow → Dex (id.203-0-113-10.sslip.io/dex)
   │   verify sign-in as alice@talu.local
   │   route match  from: ssh://app1   policy: email in [alice@talu.local]
   │   Pomerium signs a short-lived cert with its User CA  →  presented to the VM
   ▼
   to: ssh://app1-ssh.acme.svc.cluster.local:22   (the VM's ssh Service)
   ▼
   VM app1 (10.244.0.213) — logged in as talu@, cert accepted (VM trusts the User CA)
```

The routes and CA are real objects. The Pomerium config holds the SSH listener + one route per
exposed VM, each with its own allow-list — here verbatim from the live config (HTTP routes elided):

```console
$ kubectl -n pomerium get cm pomerium-config -o jsonpath='{.data.config\.yaml}'
```
```yaml
ssh_address: ":2222"
ssh_user_ca_key_file: /ssh/user_ca
ssh_host_key_files: [/ssh/host_ed25519, /ssh/host_rsa, /ssh/host_ecdsa]
routes:
  # ... HTTP routes (Dex, whoami, kubevirt-manager) elided ...
  - from: ssh://app1
    to: ssh://app1-ssh.acme.svc.cluster.local:22
    policy:
      - allow:
          and:
            - email:
                in: [alice@talu.local]
  - from: ssh://web1
    to: ssh://web1-ssh.tenant-b.svc.cluster.local:22
    policy:
      - allow:
          and:
            - email:
                in: [bob@talu.local]
```

The User CA public key is published for VMs to trust (injected into each guest via cloud-init as a
`TrustedUserCAKeys` entry — one CA, no per-VM key distribution):

```console
$ kubectl -n pomerium get cm pomerium-user-ca -o jsonpath='{.data.user_ca\.pub}'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPHybuVS+LgxKrbmAkxlTUsZBqhCAN6t+L+envUg2xaJ Pomerium User CA
```

Because authorization is per-route by OIDC email, cross-tenant SSH is denied at the proxy (bob
cannot reach `ssh://app1`), and a Cilium policy independently drops off-tenant pod traffic to the
VM's `:22` — two layers, validated both ways (see the Stage 6 multi-tenancy note above).

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
    encode at node-create time. The registry here is ClusterIP, so we pushed charts from **inside** the
    cluster (`helm push oci://registry.flux-system.svc:5000 --plain-http`). NOTE (corrected later): an
    earlier claim that "the NodePort is unreachable from the host (HTTP 000)" was **wrong** — that was a
    premature curl before the pod was Ready. A NodePort **is** reachable from the host: the host routes to
    the talos-docker node's `eth0` (`10.5.0.2`) over the `podman1` bridge, and Cilium's eBPF NodePort
    (Direct Routing on eth0) forwards it. `curl 10.5.0.2:<nodePort>` and `podman push` both work. See
    `components/tenancy/flux/README.md`.

26. **Full MicroCeph OSDs death-spiral and won't boot — recover with `bluefs-bdev-expand`, not a rebuild.**
    The lab's loop-file OSDs are tiny (created ~4 GiB each). Heavy churn (DataVolume clones, VM snapshots,
    orphaned cephfs subvolumes) fills them; once full, an OSD **aborts on startup** because BlueFS can't
    allocate the few MiB it needs for rocksdb: `bluefs _allocate unable to allocate 0x400000 ... free 0x1df000`
    → `ceph_abort_msg` → all OSDs down, PGs stale, `HEALTH_ERR N full osd(s) / pool(s) full`, and CephFS
    provisioning/attach hangs `DeadlineExceeded`. It looks like data loss but is **non-destructive to fix** —
    the OSD `block` symlinks straight to `/var/snap/microceph/common/data/osd/ceph-N/osd-backing.img` (no loop
    device), so **grow the file + expand BlueStore**:
    `snap stop microceph.osd` → for each N: `truncate -s 16G <backing.img>` then
    `microceph.ceph-bluestore-tool bluefs-bdev-expand --path /var/snap/microceph/common/data/osd/ceph-N`
    → `snap start microceph.osd`. OSDs boot, PGs go active+clean, full-flags auto-clear once usage drops
    under the ratio, MDS finishes `recovering` → `volumes: 1/1 healthy`. Then a stuck cephfs PVC needs a
    delete+recreate (an in-flight `Aborted: operation ... already exists` lock from the timed-out attempt).
    SECOND-ORDER GOTCHA: growing the backing files bloats the **host** disk (3×16 GiB); the Talos-in-Podman
    node's kubelet shares that fs, trips `node.kubernetes.io/disk-pressure=NoSchedule`, and new pods won't
    schedule. Relieve it (`podman image prune -a`) or ride the ~5-min eviction-transition hysteresis; a tiny
    test pod can also just **tolerate** `node.kubernetes.io/disk-pressure`. Real fix long-term: reclaim the
    orphaned cephfs subvolumes / RBD images (bluestore won't shrink the file, so cleanup frees ceph space but
    not host disk) or run non-nested with real disks. This is a lab-substrate limit, **not** a Talu/Velero bug.
    This is a **known** BlueStore failure mode: the DB/data are collocated so data uses a 4K alloc unit but
    BlueFS/DB needs contiguous 64K blocks — near-full there's free space overall but no contiguous 64K run.
    Upstream's documented remedy is exactly this (expand by as little as 1 GiB), plus a follow-up
    `ceph-bluestore-tool repair`; Rook automates it in an `expand-bluefs` init container. Refs:
    [ceph tracker #53899](https://tracker.ceph.com/issues/53899),
    [#53466](https://tracker.ceph.com/issues/53466),
    [rook#6530](https://github.com/rook/rook/issues/6530).

27. **Velero fs-backup (kopia/restic) SKIPS `hostPath`-backed volumes — `local-path` PVs are hostPath, so
    they produce NO PodVolumeBackup.** A backup of a `local-path` PVC `Completes` with `warnings=1` and
    silently creates zero PodVolumeBackups — Velero's node-agent excludes hostPath volumes by design. Use a
    **real CSI filesystem volume (CephFS here)** to exercise fs-backup. Validated end-to-end on CephFS:
    marker file → `defaultVolumesToFsBackup: true` Backup → `PodVolumeBackup Completed (kopia, 19 bytes)` →
    **destroy the whole namespace (pod+PVC+PV+subvolume)** → Restore → `PodVolumeRestore Completed` recreates
    the pod on a **new PV** and its `restore-wait` init container kopia-restores the data → the marker
    survives byte-for-byte. Also needs the `velero` ns labelled `pod-security...enforce=privileged` (#5) or
    the node-agent DaemonSet gets 0 pods (it mounts `/var/lib/kubelet/*` hostPaths).

28. **MinIO → Garage for the Velero S3 target (MinIO's OSS edition is archived).** MinIO removed the
    admin console from Community Edition (May 2025), pulled the community docs (Oct 2025), and the
    `minio/minio` repo was **archived read-only in 2026** — no CVE stream for a tier that must stay
    restorable for years. [Garage](https://garagehq.deuxfleurs.fr/) (Deuxfleurs, AGPLv3, Rust, ~50 MB)
    is a drop-in for the **stock `velero-plugin-for-aws`** — validated end-to-end here, kopia included.
    Its footprint is 3–6× smaller, which matters on this node (see #25/#26). Two traps when migrating:
    - **The credentials Secret is named `velero`, not `cloud-credentials`.** The Deployment mounts a
      *volume* called `cloud-credentials` whose `secretName` is `velero`. Creating a Secret literally
      named `cloud-credentials` changes nothing and the BSL keeps failing against the OLD backend
      (`AccessDenied: Forbidden: No such key: minio`). Confirm with
      `kubectl -n velero get deploy velero -o jsonpath='{.spec.template.spec.volumes[*].secret.secretName}'`.
    - **Delete the stale `BackupRepository`** (`kubectl -n velero delete backuprepository --all`) when
      repointing, or kopia keeps addressing the old bucket. Then restart `deploy/velero` + `ds/node-agent`.
    Also: **Garage stores nothing until a layout is applied** — `garage layout assign -z <zone> -c <cap>
    <node-id>` then `garage layout apply --version 1`, else `garage status` shows `NO ROLE ASSIGNED`.
    Trade-off accepted: Garage has **no S3 Object Lock** (no WORM immutability) — see
    [S3 compatibility](https://garagehq.deuxfleurs.fr/documentation/reference-manual/s3-compatibility/)
    and the caveat in [`../operations/backup-restore.md`](../operations/backup-restore.md).

29. **`lab_floating_ip` stale → Dex issuer domain wrong → every Pomerium sign-in 500s.** `lab_domain`
    is derived from `lab_floating_ip` in `ansible/group_vars/all.yml`. If it's left at the
    `203.0.113.10` example placeholder (not the real VM IP), Dex is deployed with
    `issuer: https://id.203-0-113-10.sslip.io/dex`, but Pomerium's `idp_provider_url` uses the real
    domain — so OIDC discovery mismatches and sign-in fails: `identity/oidc: could not connect to oidc:
    oidc: issuer URL provided to client (...) did not match the issuer URL returned by provider (...)`,
    HTTP 500 on `/.pomerium/sign_in`. The symptom looks like a broken IdP; it's a stale variable.
    Fix: set `lab_floating_ip` to the real IP (keep it in sync with `env.sh` LAB_SSH on every reinstall),
    re-run `--tags dex`. (For a one-off live patch, edit the `dex` ConfigMap's `issuer`/`redirectURIs`
    and restart Dex — but fix the variable so it survives.)

30. **Cilium install hard-fails on a fresh cluster: "Service Monitor requires monitoring.coreos.com/v1
    CRDs".** Talu's Cilium/Hubble values enable ServiceMonitors, but the prometheus-operator CRDs are
    installed later (by the `monitoring` role) — chicken-and-egg. The `cilium` role now applies the
    servicemonitors/podmonitors/prometheusrules CRDs (pinned `prometheus_operator_crd_version`) BEFORE
    the Cilium helm install; the monitoring HelmRelease (`crds: CreateReplace`) reconciles them later.

31. **A host reboot can wedge KubeVirt's containerDisk data-path — the fix is recreating the NODE, not
    restarting it.** After an unclean reboot (e.g. a force-killed shutdown that hung on stuck rbd-nbd
    devices — see #14/#15), containerDisk VMs churn at `Scheduled`: the launcher's `volumecontainerdisk`
    creates its socket then it "does not exist anymore" and exits, and `/var/run/kubevirt-ephemeral-disks`
    never appears on the node. This SURVIVES every targeted restart — virt-handler, kubelet, a `podman
    restart` of the node container, SELinux permissive, even a full KubeVirt reinstall (delete/recreate
    the CR). Ruled out: Ceph/snap (healthy), host+node mount propagation (`shared`), SELinux (no denials),
    certs (present). It's baked into the node container's post-reboot state; only recreating the node
    clears it. `make up` (talos_cluster) destroys+recreates the node → fixed; then re-run the stack
    (ansible) and redeploy tenants. NOTE: `talos_cluster` is idempotent and SKIPS create if the container
    exists — so `make down`/`talosctl cluster destroy` first, or it just reconfigures the broken node.
    Loop devices must be re-attached after a host reboot (`dev/loopdev/setup.sh up`) before the node
    container will start (it binds `/dev/loopN`).

32. **The SSH principal is per-tenant, not always `talu`.** `ssh <principal>@<vm>@ssh.<domain> -p 23`
    (Pomerium Native SSH) — the FIRST token is the guest Linux user = the tenant's `principal`
    (`defaults.principal`, or a per-VM override in the values). e.g. `acme`'s app1 sets `principal: alice`,
    so it's `ssh alice@app1@ssh.<domain> -p 23`, NOT `talu`. Connecting as the wrong principal =
    `Permission Denied` from the guest sshd (Pomerium authenticates + authorizes fine — the log shows
    `successfully authenticated` + `allow:true` — then the VM rejects the cert because that user doesn't
    exist). The `vm-ssh.sh` helper defaults to `talu`; pass the principal: `vm-ssh.sh app1 alice`. Find a
    VM's principal: `kubectl -n <ns> get secret <vm>-userdata -o jsonpath='{.data.userdata}' | base64 -d
    | grep -A1 'users:'`. (Also: the login IDENTITY `alice@talu.local` and the guest principal `alice`
    are independent — one is gated by the route allow-list, the other is which Linux account you land in.)
    Platform-side SSH audit caveat: Pomerium's OSS SSH authorize log carries email + time + allow but the
    target VM only as an opaque `route-checksum` (host/route-id empty for SSH) — so who+when is auditable,
    per-VM-name filtering is not (without a checksum→VM map or Hubble flow correlation). See the logging
    component's Access Audit dashboard + README.



33. **KubeVirt's `guest-console-log` is a native-sidecar initContainer, and an idle guest is silent.**
    The VM's serial console is captured into a container named `guest-console-log` in the virt-launcher
    pod — but it's an **initContainer** (a `restartPolicy: Always` native sidecar), NOT in `.spec.containers`.
    Alloy's `discovery.kubernetes role=pod` DOES discover it (with `__meta_kubernetes_pod_container_init=true`)
    and `loki.source.kubernetes` tails it, so no special config is needed — BUT after boot an idle guest
    writes nothing to serial, so the stream looks empty. That's why VM-logs **Tier 1 streams the journal to
    the serial console**: it keeps runtime logs flowing, not just the boot messages.
    **Use a `journalctl -f > /dev/console` SERVICE, not journald's `ForwardToConsole`.** Two traps here,
    learned the hard way:
    (a) *Write to `/dev/console`, never `/dev/ttyS0`.* `serial-getty@ttyS0` takes EXCLUSIVE ownership of
    `/dev/ttyS0`, so anything that opens ttyS0 for log output after getty is up silently gets nothing.
    `/dev/console` is the kernel console multiplexer — writes reach ttyS0 (via `console=ttyS0` on the guest
    cmdline) regardless of getty. A direct `echo x > /dev/console` DOES land in guest-console-log; `> /dev/ttyS0` does not.
    (b) *journald `ForwardToConsole=yes` is RACY under cloud-init and can't be trusted.* journald only
    (re)attaches console forwarding at start, and cloud-init's `runcmd systemctl restart systemd-journald`
    runs at an unpredictable point — sometimes it forwards (you see `[monotonic] unit[pid]:` lines),
    sometimes it silently doesn't, on byte-identical config. A dedicated unit that runs
    `journalctl -b -f -o short-iso --no-hostname -p <level> > /dev/console` (Restart=always) is
    deterministic and getty-independent — this is what the tenant chart (`talu-console-logs.service`) ships.
    Symptom of getting it wrong: the operator VM Logs dashboard shows the VM but no ongoing messages, even
    though `journalctl` *inside* the guest has the events.
    Verify the WHOLE guest path (NOT getty echo, which is a false positive — typing at the console just
    echoes back) by firing an EXTERNAL SSH at the VM and confirming the sshd lines land in Loki:
    `ssh -o ConnectTimeout=6 probe@<vmi-ip> true` (from a pod in the `pomerium` ns, which the ssh-pin
    allows) → `{namespace=<ns>, vm=<name>, container="guest-console-log"} |~ "sshd"`. Note the `vm` label
    is stamped by Alloy from `kubevirt.io/vm` pod metadata (spoof-proof) and applied to ALL of the pod's
    containers, so scope guest logs with `container="guest-console-log"`. Also: the console stream carries
    blank getty lines — filter them in dashboards with `|~ "\\S"`, or every row renders as just the
    `<ns>/<vm>` prefix with no content ("I only see acme/app1").

34. **Cilium on the nested lab: default-deny on a pod starves the kubelet readiness probe; deny-only
    policies are a footgun.** Two traps hit while building the VM-logs Tier-2 Loki lockdown:
    (a) Any `CiliumNetworkPolicy` with an `ingress:` allow-list flips the selected endpoint to
    ingress-default-deny on ALL ports — so you must also allow Loki's own namespace (memberlist 7946,
    gRPC 9095) AND the kubelet health probe. In this nested Talos-in-Podman cluster the `:3100/ready`
    probe source is **not** classified as `host`/`remote-node`/`health`, so even
    `fromEntities: [host, remote-node, health]` doesn't cover it — Loki flaps NotReady and (fatally) drops
    out of its Service endpoints, so EVERY reader then gets connection-refused (looks like "the policy
    blocks everyone"). (b) A **deny-only** policy (`ingressDeny` with no `ingress`) still enables
    default-deny in this Cilium (footgun), and adding `enableDefaultDeny.ingress: false` to opt out
    *disables enforcement of the deny itself* — so neither deny-only form both keeps Loki reachable AND
    blocks VMs. Net: the `loki-ingress-policy.yaml` allow-list is correct on a normal cluster but is NOT
    applied on the lab; the enforced spoof-defense is the per-tenant ingest gateway's hard-stamping.
    Debugging aid: a `000`/connection-refused from a test curl is often a **short-name DNS miss**
    (`svc:3100` vs `svc.cluster.local:3100`) or **no ready Service endpoints**, NOT a policy drop — always
    retest with the FQDN and confirm the target pod is Ready before blaming the policy.

35. **SSH User CA trust must be PACKAGE-owned to be rotatable — cloud-init hand-writing it is a dead end.**
    Trust lives in `/etc/ssh/talu_ca.pub` (`TrustedUserCAKeys`). If cloud-init *writes* that file, you can
    never rotate the CA on a running VM without either SSHing in (which the platform refuses to do) or
    recreating the VM: (a) on **bootc/ostree** guests a file modified after provisioning is a local `/etc`
    override that the image update WON'T overwrite; (b) on mutable guests it's an unmanaged file nothing
    updates. The fix is the **`talu-ca-trust` package** (`images/ca-trust/`): dpkg/rpm own the file, so a
    CA rotation is just a package upgrade (`unattended-upgrades` on mutable guests, reboot-less; the bootc
    image update on ostree guests). The package's `postinst` **reloads** sshd (never `restart` — that would
    drop the live session, including the platform's own). Rotation is dual-trust: `TrustedUserCAKeys` accepts
    multiple CA keys, so the file carries CA1+CA2 during the window (`dev/lab/ca-rotate.sh prepare` →
    `switch` → `retire`). Opt in per tenant with `caTrust.package=true` (needs an apt/rpm repo the guests can
    reach); the default still hand-writes the file (simplest, but the CA is then only rotatable by recreating
    the VM — fine for ephemeral containerDisk VMs). Build the .deb with only coreutils+tar+ar (no dpkg-deb),
    so it builds on the rpm-based lab host too; validated installing on Ubuntu 24.04 (`dpkg -S` shows it owns
    the file).
