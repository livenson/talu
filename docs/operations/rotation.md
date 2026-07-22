# CA & secret rotation

## SSH User CA — dual-trust, zero lockout, no platform-SSH

The Pomerium **SSH User CA** signs the certs users present to VMs; the VMs trust it via
`TrustedUserCAKeys`. Rotating it naively would lock every guest out. Talu rotates it with a **dual-trust
window**, distributing trust through the [`talu-ca-trust` package](../../images/ca-trust/) — the platform
**never SSHes into a guest**.

```sh
dev/lab/ca-rotate.sh status                # where the rotation stands

dev/lab/ca-rotate.sh prepare               # 1. generate CA2; trust BOTH (ConfigMap + package v2);
                                           #    the signer is STILL CA1 — nothing breaks yet
#   → roll the new package to guests: package-mode VMs auto-update (unattended-upgrades / bootc image);
#     new VMs get dual-trust from the ConfigMap. CONFIRM every guest trusts BOTH before continuing.

dev/lab/ca-rotate.sh switch                # 2. Pomerium signs with CA2 now; guests trust CA1+CA2 (safe)
#   → grace window: let any CA1-signed sessions age out.

dev/lab/ca-rotate.sh retire               # 3. trust CA2 ONLY (package v3); drop CA1. Rotation complete.
```

**Why the package matters:** a *running* VM's trust file can only change if something updates it. We
refuse to have the platform SSH in, so trust rides the OS update channel — hence
`caTrust.package=true` on tenants whose CA you intend to rotate (mutable guests auto-update reboot-less
from the in-cluster [`pkg-repo`](../../components/platform/pkg-repo/); bootc guests pick it up on their
next image update). Deploy the repo once (`kubectl apply -k components/platform/pkg-repo`); `ca-rotate.sh`
publishes each new package version to it automatically. Full package pipeline: [packages.md](packages.md). Tenants left on the default hand-written trust
(`caTrust.package=false`) only adopt a rotated CA when their VMs are **recreated** — fine for ephemeral
`containerDisk` VMs, but you can't safely `retire` the old CA until every VM has the new trust.

Package versions increase monotonically (a counter on the `pomerium-user-ca` ConfigMap annotation
`talu.io/ca-pkg-version`), so repeated rotations always publish a *higher* version than guests have —
otherwise dpkg/rpm (which install the highest) would never pick the new one up. (The in-cluster Job
takes an explicit `VERSION` the operator/CI bumps.)

*Validated on the lab (the money shot):* a running Ubuntu guest with the package installed, then a CA
rotation published as a new package version → `apt update && apt upgrade` moved the guest to the new
version and its `/etc/ssh/talu_ca.pub` **gained the new CA** (v1→v2, 1→2 keys, the rotated key present) —
**reboot-less**. Also verified: `prepare` stages CA2 + publishes dual-trust without disrupting the signer.
`switch`/`retire` aren't run on the single-node lab because its `app1` still uses the default CA1-only
trust — switching would lock it out, which is exactly the point of the package path.

## Platform secrets — update + restart

Pomerium and Dex re-read their secrets on start, so rotation is "patch the Secret, restart the consumer":

```sh
dev/lab/secret-rotate.sh <namespace> <secret> <key> <deployment> [<new-value>]
# e.g. a random new Pomerium bootstrap/cookie secret:
dev/lab/secret-rotate.sh pomerium pomerium bootstrap pomerium
```
For a **shared** secret (e.g. the Dex↔Pomerium client secret) pass the same explicit `<new-value>` on
both sides so they stay in step.

## TLS certificates — automatic

cert-manager **auto-renews** the internal TLS leaf certs and Pomerium's autocert handles its public
certs — there is no rotate step. (Follow-up: add a cert-manager `ServiceMonitor` + a
`TaluCertExpiringSoon` alert — cert-manager isn't scraped yet, so the metric
`certmanager_certificate_expiration_timestamp_seconds` isn't available.)
