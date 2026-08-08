# ADR — replace `route-sync` with Pomerium's Ingress Controller

**Status:** Proposed · 2026-08-08 · supersedes the `allowedUsers` inversion planned in
[`adr-api-layer.md`](adr-api-layer.md) §10.1 (see §5 — that work should **not** be done).

**Decision in one line:** stop rendering Pomerium's route list from a CronJob and let **routes be
Kubernetes objects** — `Ingress` resources emitted by the charts that already create the workloads.

---

## 1 · What `route-sync` does, and why it exists

Pomerium's routes live in **one shared config blob** (`pomerium-config`), and no Helm chart can own a
*fragment* of a shared blob. So [`route-sync`](../../components/tenancy/flux/route-sync.yaml) is a
CronJob that, every 2 minutes, re-renders the whole thing: a base block (`perses`, `hubble`,
`alertmanager`, `id`) plus routes discovered from labelled Services —

| label | renders |
|---|---|
| `talu.io/ssh-expose` | `ssh://<vm>` → the VM's ssh Service, allow-list from `talu.io/allowed-users` |
| `talu.io/dashboard-expose` | `https://<ns>-dashboard.<domain>` |
| `talu.io/landing-expose` | public apex `https://<domain>` |

It then writes the ConfigMap and rolls Pomerium. It is `dev/lab/expose-vm.sh` step 2, promoted
in-cluster. On the phys lab it currently renders **3 live `ssh://` routes**.

The design is not a mistake — given "routes are one blob", a periodic renderer is a reasonable answer.
The file's own header already names the exit: *"A watch-based controller — or Pomerium Ingress mode
making routes objects — is the cleaner long-term."*

## 2 · Why it should go

1. **Two writers of one blob.** `phys_identity` renders `pomerium-config` from Ansible; `route-sync`
   re-renders the *whole* blob every 2 minutes and applies last, so it decides the live domain. This
   is [`lab-notes.md`](../development/lab-notes.md) **#40** — a 404 on *every* host, with a
   misleading TLS warning as the visible symptom.
2. **Whole-blob rewrite ⇒ whole-plane blast radius.** One malformed route takes down every route.
3. **Poll, not level-trigger.** Up to 2 minutes before a new VM is reachable, and the same lag on
   deletion.
4. **Shell + jsonpath templating**, with `au=${au:-alice@talu.local}` — a hardcoded lab identity as
   the default allow-list. Quoting bugs here fail silently.
5. **Cluster-wide `services` list + `configmaps` patch in the access plane.** Compromise it and you
   rewrite who can reach what.
6. **No feedback.** A route that fails to render reports nothing — the same silent-failure shape that
   produced three separate incidents while building the typed API (a CRS config that watched nothing,
   a ServiceMonitor matching no Service, a PrometheusRule evaluating a dead metric).

## 3 · The alternative

[Pomerium's Ingress Controller](https://www.pomerium.com/docs/deploy/k8s/ingress) provisions routes
from `Ingress` objects, with authorization policy in annotations. Critically for Talu, it supports
**native SSH upstreams** via `ingress.pomerium.io/ssh_upstream: "true"`
([reference](https://github.com/pomerium/ingress-controller/blob/main/reference.md)) — so the SSH
case, which is the reason `route-sync` exists at all, is covered rather than left behind.

What changes:

- **Routes become objects the charts already render.** `talu-vm` emits the VM's `Ingress` next to its
  `Service`; `talu-tenant` emits the dashboard's. That is exactly Talu's existing model — the chart
  renders the tenant bundle — instead of a job reverse-engineering the bundle from labels.
- **Deleting a tenant deletes its routes** by ordinary garbage collection.
- **Level-triggered**: routes exist when the object does.
- **One writer.** The blob-merge conflict and #40 disappear by construction.
- **Per-route blast radius.** A malformed `Ingress` breaks that route only.

## 3b · Decided: the controller SUPERSEDES the current deployment

Does the controller *manage* the existing Pomerium, or *replace* it? **It replaces it.**

The rationale is the defect this ADR exists to fix. `route-sync`'s problem is not that it is a
CronJob — it is that **two things own the same logic** and the last writer wins (lab-notes #40).
Running the controller beside an Ansible-templated `config.yaml` would reproduce exactly that defect
behind a better-looking mechanism, and briefly make it three writers instead of two.

So there is one owner of Pomerium's configuration at every point in time:

- `phys_identity` stops templating `pomerium-config`; Pomerium is deployed as the
  **ingress-controller** image, which ships its own Deployment, Namespace and IngressClass.
- **Every route becomes an `Ingress`** — including the base ones. Checked against the
  [CRD reference](https://github.com/pomerium/ingress-controller/blob/main/reference.md):
  **routes cannot be expressed in the `Pomerium` CRD at all**; it is global configuration only. An
  earlier draft of this ADR said base routes "move into the CRD" — that was wrong, and it changes
  step 5 below.
- The **`Pomerium` CRD holds global settings**: `identityProvider`, `authenticate` (required),
  `secrets` (required — `shared_secret`/`cookie_secret`/`signing_key`), `certificates`,
  `certificateAutoProvision`, `storage`, cookie/DNS/timeout/header settings, and an `ssh` block with
  `hostKeySecrets` and `userCaKeySecret`.
- Per-workload routes are `Ingress` objects owned by the charts that create the workloads.

Two consequences of that correction, both good:

- **Base routes get owners.** `perses` and `alertmanager` belong to the monitoring component,
  `hubble` to Cilium, `id` to identity — each renders its own `Ingress`, exactly as tenants render
  theirs. Nothing is left in a shared blob for a job to reconstruct.
- **Talu's Pomerium-as-SSH-CA design maps onto the CRD directly** (`ssh.hostKeySecrets`,
  `ssh.userCaKeySecret`), which was the piece most at risk of not being expressible. The `pomerium-ssh`
  Secret and the `pomerium-user-ca` ConfigMap that tenant VMs already trust keep their roles.

### Certificates — decided: `certificateAutoProvision` (cert-manager)

Talu currently uses Pomerium **autocert** (Let's Encrypt, HTTP-01). The CRD offers `certificates`
(explicit TLS Secrets) or `certificateAutoProvision` (cert-manager issues per-route certs). **Use
`certificateAutoProvision`.**

The reasoning is this ADR's own principle applied once more: today Pomerium's autocert and
cert-manager are **two independent ACME clients** in one cluster, each with its own retry behaviour
and its own view of rate limits. cert-manager is already a platform component (internal CA,
`talu-apiserver` serving certs, Rook), so consolidating on it means one issuer, one place to reason
about limits, and certs stored as ordinary Secrets that survive a Pomerium restart rather than living
in Pomerium's own storage.

It also directly addresses a failure this lab has already had: lab-notes records an **hour-long
Let's Encrypt rate-limit lockout** — "too many failed authorizations (5) per hostname per hour" —
caused by Pomerium retrying aggressively against the prod ACME endpoint over an unstable inbound
forward, after which Pomerium served the wrong hostname's certificate and broke the whole OIDC login
even for hosts whose certs were valid. cert-manager's backoff is far better behaved.

**What it does NOT fix, and this must not be glossed:** the root cause there was the flaky inbound
`:80`/`:443` provider forward, and HTTP-01 still needs that path. cert-manager handles the failure
more gracefully; it does not make it succeed. The real fix is **DNS-01**, which needs DNS API
credentials for the site domain — worth deciding separately, and worth using LE **staging**
(`autocert_use_staging`-equivalent) while iterating, exactly as lab-notes advises, rather than
re-locking the hour.

**This changes the staging plan.** "Install alongside" is not available when the thing supersedes:
the cutover is a single moment, not a gradual overlap. What can still be staged is everything
*before* it — the Ingress objects and the `Pomerium` CRD can be created while the old Pomerium is
still serving, because nothing reconciles them until the controller exists. Rollback is redeploying
the old Pomerium from `phys_identity`, so its `config.yaml` template must be **kept** until the new
path is proven — deleting it in the same change would remove the way back.

### The domain becomes a render-time input, everywhere

`route-sync` resolved the site domain at **run** time from the `talu-platform` ConfigMap (lab-notes
#40: that ConfigMap is the single source both writers read). An `Ingress` host must be **concrete at
render time**, so every route that carries a hostname now needs the domain supplied where it is
rendered. This is a real loss of late binding, not a detail, and it lands differently per component:

- **Helm charts** (`talu-tenant`, `talu-vm`) take it as a value — done, with a `required` guard,
  because an empty domain renders `host: <slug>-dashboard.` and 404s in a way that looks like a
  Pomerium fault rather than a values fault.
- **Kustomize components** (monitoring, Cilium, identity) have no equivalent. **Decided: the owning
  ansible role templates the host**, as `phys_identity` already templates `lab_domain` today.

  Two alternatives were considered and rejected:
  - *kustomize `replacements` from the `talu-platform` ConfigMap* — replacements source from other
    manifests **inside the same build**, not from a live cluster object, so this cannot read a
    ConfigMap that only exists at runtime.
  - *an `environments/<site>/` overlay patching the host* — idiomatic for this repo in general, but
    the physical lab does not deploy through its environment overlay: `phys-stack.yml` applies each
    component with `kubectl apply -k <component>` on the gateway, so an overlay-level patch would
    never be evaluated. (`environments/rocky-phys/kustomization.yaml` exists only so `make kbuild`
    has something to build.)

  Role-templating costs nothing the ADR cares about: the routes are still **objects** — garbage
  collected with their workload, one route per failure domain, one writer. "Rendered by Ansible" is
  not the defect being removed; **"reconstructed by a job from labels, into a blob two things write"**
  is.

Getting it wrong reintroduces exactly what this ADR removes: a hostname that only one writer knows.

### `route-sync` is not merely redundant after the swap — it is hostile

Worth stating precisely, because the obvious assumption ("it writes a ConfigMap nobody reads, so it
is harmless") is wrong. Its last step is:

```sh
kubectl -n pomerium create cm pomerium-config ... | kubectl apply -f -
kubectl -n pomerium rollout restart deploy/pomerium
```

It restarts Pomerium **whenever its render differs from the live ConfigMap**. After the swap the new
Pomerium takes its configuration from the `Pomerium` CRD and `Ingress` objects, so `pomerium-config`
is orphaned — route-sync's comparison then differs on every cycle, and it **restarts the new Pomerium
every 2 minutes**. The Deployment keeps its name, so it is the *new* access plane being rolled, on a
loop, looking exactly like a failed migration.

Hence: suspend it in the same action as the swap, not afterwards.

**And on keeping it as a rollback aid:** that argument is weaker than it looks. Rollback is
`kubectl apply -k components/tenancy/flux` plus unsuspend — **git is the rollback**, not the running
CronJob. Leaving it installed-but-suspended is simply cheaper under pressure than reinstating it
mid-incident; it is not a dependency. Deleting it at step 6 loses nothing.

## 4 · Costs and risks — this is an access-plane migration

The access plane is the highest-blast-radius component in Talu and the lab has **no console and no
BMC**, so a mistake is unrecoverable remotely. Specifically:

- Pomerium must run in Ingress-controller mode, and the base routes move into the `Pomerium` CRD's
  global settings — a real change to `phys_identity`, not a values tweak.
- **Verified on the lab (2026-08-08):** Pomerium is **v0.33.0**, with **no `pomerium.io` CRDs** and
  **no IngressClass** — the controller is genuinely not deployed yet, so nothing here is a
  half-migration to unpick.
- **Version support confirmed:** `ingress-controller` releases track Pomerium's (v0.33.0 on
  2026-07-16, **v0.33.1** on 2026-08-05), and SSH support landed in
  [PR #1175 "add ssh settings"](https://github.com/pomerium/ingress-controller/pull/1175), merged
  **2025-06-27** — a year before v0.33. So the installed version can do this; no Pomerium upgrade is
  a prerequisite, though v0.33.1 is available.
- Every consumer of the current labels (`dev/lab/expose-vm.sh`, the charts, `phys_identity`) has to
  move together or be kept working during the overlap.

## 5 · Consequence for the typed API work

[`adr-api-layer.md`](adr-api-layer.md) §10.1 defers moving `allowedUsers` off the ssh `Service`
annotation, so that `route-sync` would read it from the `Tenant` instead. **That work should not be
done.** Under Ingress mode there is no scraping at all: the chart puts the policy on the `Ingress` it
renders, from values it already holds. Doing the annotation inversion first is effort thrown away.

## 6 · Staging

Deliberately incremental, with a rollback at every step. `route-sync` stays installed and suspendable
throughout (`kubectl -n pomerium patch cronjob route-sync -p '{"spec":{"suspend":true}}'`).

Revised for §3b. Everything up to the swap is inert and reversible; the swap is the only step that
can break access, so everything it needs exists and has been reviewed before it happens.

1. ~~Confirm v0.33 supports the Ingress controller and `ssh_upstream`.~~ **Done** — SSH support
   predates v0.33 by a year (§4), so no Pomerium upgrade is a prerequisite.
2. ~~Install the CRDs.~~ **Done** — applied on `rocky-phys` from the v0.33.1 manifest, **CRDs only**,
   no controller. Verified non-destructive: 3 `ssh://` routes still live, Pomerium `Running`. The
   manifest splits cleanly, which is what makes the rest stageable.
3. **Prepare, inert.** `talu-vm` renders the ssh `Ingress` (done, `ingress.enabled: false`);
   `talu-tenant` renders the dashboard `Ingress`; author the `Pomerium` CRD carrying base routes and
   global settings. None of it reconciles while no controller runs, so all of it can be applied and
   reviewed against the live cluster first.
4. **Swap.** Replace the Pomerium Deployment with the ingress-controller image and set
   `ingress.enabled: true`. **Suspend `route-sync` ATOMICALLY with the swap** — see the hazard below;
   this is not housekeeping that can follow later. Do not delete it yet.
   Rollback: redeploy the old Pomerium from `phys_identity`, unsuspend `route-sync`.
5. **Verify every route CLASS** before touching anything else: an ssh route, a tenant dashboard, each
   base route, the public apex. A 404 on one class is recoverable at that moment and much less so
   later.
6. **Then** delete `route-sync`, its RBAC, the `talu.io/*-expose` label contract, and
   `phys_identity`'s `config.yaml` template — in that order, once nothing depends on them.

---

## 7 · Field-by-field audit of `phys_identity`'s Pomerium templates

Staging step 3 called for reading
[`pomerium.yaml.j2`](../../ansible/roles/phys_identity/templates/pomerium.yaml.j2) end to end against
the CRD field list before any `kubectl apply`. Done — against the **CRD as installed on `rocky-phys`**
(`kubectl explain pomerium.spec --recursive`), the v0.33.1 bundled manifest, the controller source,
and the **live** `pomerium-config`. It changes the plan in several places, so it is recorded here
rather than left in a session.

### 7.1 · Every config key, and where it goes

| `config.yaml` today | Destination under the controller |
|---|---|
| `autocert` / `autocert_dir` | **Gone** — replaced by `certificateAutoProvision` (§3b). The `pomerium-autocert` RWO PVC and `strategy: Recreate` go with it. |
| `metrics_address: ":9902"` | Controller flag `--metrics-bind-address=$(POD_IP):9090`; the bundled `pomerium-metrics` Service is **:9090**. |
| `http_redirect_addr: ":80"` | Flag `--http-redirect-addr`, default **`:8080`** — the container listens on 8080/8443, the Service maps 80/443 onto them. |
| `ssh_address: ":2222"` | Flag `--ssh-addr`, **default empty ⇒ the SSH server does not start**. Not in the bundled manifest at all. |
| `ssh_user_ca_key_file: /ssh/user_ca` | `spec.ssh.userCaKeySecret: <ns>/<name>` |
| `ssh_host_key_files: [3 paths]` | `spec.ssh.hostKeySecrets: [<ns>/<name>, …]` — a list of **separate Secrets** |
| `authenticate_service_url` | `spec.authenticate.url` (required) |
| `idp_provider` / `idp_provider_url` / `idp_scopes` | `spec.identityProvider.{provider,url,scopes}` |
| `idp_client_id` / `idp_client_secret` | `spec.identityProvider.secret: <ns>/<name>`, a Secret with `client_id` + `client_secret` |
| — (nothing today) | `spec.secrets` — **required** |
| `routes:` | `Ingress` objects |

Every `<ns>/<name>` above is parsed by `util.ParseNamespacedName`: the **namespace-qualified** form is
mandatory, a bare name is an error.

Three of these are new work rather than a transcription:

- **`spec.secrets` is required and does not exist yet.** It must hold `shared_secret`, `cookie_secret`
  **and `signing_key`**. The live `pomerium-secrets` has two keys, `SHARED_SECRET` and `COOKIE_SECRET`
  — env-var spellings consumed via `envFrom`, with no signing key. The Secret has to be rebuilt with
  the lowercase names, or generated by the bundled `pomerium-gen-secrets` Job into `pomerium/bootstrap`.
  (If that Job is used: the bundled manifest pins it to `pomerium/ingress-controller:**main**` while the
  controller is `v0.33.1` — pin it before applying.)
- **The SSH Secret has the wrong shape.** `pomerium-ssh` is one `Opaque` Secret with five keys
  (`host_ed25519`, `host_rsa`, `host_ecdsa`, `user_ca`, `user_ca.pub`). The controller requires **four
  separate Secrets**, each of type **`kubernetes.io/ssh-auth`** with the key **`ssh-privatekey`** —
  `SSHSecrets.Validate()` rejects any other type, and `applySSH` errors on a missing `ssh-privatekey`.
  **The `user_ca` private key must be carried across byte-identical**: every tenant VM already trusts
  `user_ca.pub` via cloud-init `TrustedUserCAKeys`, so regenerating it locks every existing VM out of SSH.
- **The Dex client secret stops living in a ConfigMap.** Today `idp_client_secret` is templated in
  plaintext into `pomerium-config`; the CRD only accepts a Secret reference. A small security
  improvement that falls out of the migration.

### 7.2 · Two defects in already-merged chart templates

- **`vm-chart`'s ssh Ingress would be rejected outright.** It renders `path: /` with
  `pathType: Prefix`; `setRoutePath` requires `pathType: ImplementationSpecific` **and an empty path**
  for an `ssh_upstream` route, erroring with *"ssh services must have ImplementationSpecific path
  type"*. As merged, the swap produces **zero** working ssh routes. (The bare `host: <vm>` is right —
  `setRouteFrom` rewrites the scheme to `ssh://`, reproducing route-sync's `ssh://<vm>` exactly.)
- **Neither chart Ingress carries `spec.tls`.** Not fatal — TLS is only *required* on an Ingress that
  uses `spec.defaultBackend` (where the host is derived from it) — but a route with no `spec.tls`, no
  `spec.certificates` entry and no auto-provisioned cert simply has no certificate. §7.3 says which
  applies.

### 7.3 · What `certificateAutoProvision` actually covers

PR #40's decision stands, with a correction and a gap. The CRD's own description calls it "a fallback
for routes that are not defined via Ingress or Gateway resources", which reads as *Ingress routes are
not covered*. The implementation is broader: `GetNamesFromConfig` collects the hostname of **every**
route in the databroker, Ingress-derived included, and `MissingNames()` is every such hostname with no
matching certificate. So ordinary dashboard and base routes **are** auto-provisioned.

Two consequences worth knowing before the swap:

- **`ssh://` routes are excluded** by a scheme filter (`!strings.Contains(u.Scheme, "https")`). No ACME
  order is attempted for a bare VM name — which would otherwise fail and burn the failed-authorization
  budget that already caused an hour-long lockout. Note `tcp+https`/`udp+https` are **not** excluded.
- **`authenticate.<domain>` is NOT auto-provisioned.** Settings records contribute *certificate* names
  only, never route names, so the authenticate hostname is never "missing" and no `Certificate` is
  created for it. The CRD says as much: create the Secret yourself and reference it via
  `spec.certificates`, solving HTTP-01 through the `pomerium` ingressClass. That is a **chicken-and-egg
  at cutover** — Pomerium must already be serving `:80` to obtain the certificate that makes login work
  — and it is the one certificate whose absence breaks *every* authenticated route at once.

Two smaller traps: a Secret named in `spec.certificates` that does not exist is **silently skipped**
with a log line and no status condition (the house failure mode again — §"Silent failure" in the lab
notes), and the lab currently has **only a `selfsigned` ClusterIssuer**. An LE **staging** issuer and
an LE production issuer both have to exist before the swap, with staging used while iterating.

### 7.4 · The route inventory in §1 is wrong, and short by two classes

§1 lists the base routes as `perses`, `hubble`, `alertmanager`, `id`. Checked against the live blob:

- **`alertmanager` is not on the physical lab.** It exists only in route-sync's *built-in fallback*
  block, which phys never uses — phys supplies `pomerium-base`, and that has no alertmanager route.
- **`vms` (kubevirt-manager) and the public apex are base routes** and are missing from §1.
- Two further classes exist that this ADR has never mentioned:
  - **`k8s-<tenant>` — the KaaS tenant kube-apiserver routes** (two live), and
  - **`clusters` — Headlamp.**

The live blob is **12 routes across 6 classes** (an earlier revision of this section said 11 — a
miscount; the apex appears twice, once from the base and once from a `talu.io/landing-expose`
Service). Note also that **no tenant dashboard route is live**, so that class has never run in anger
here and step 5 will be exercising it for the first time. Staging step 5 ("verify every route class") was
written against a list that would have missed three of them.

### 7.5 · The KaaS `k8s-<tenant>` routes cannot be expressed as Ingresses at all

**This section replaces an earlier version that was wrong in both directions.** It claimed the blocker
was the upstream (`to: https://172.18.200.1:6443` — "a bare IP, not a Service") and proposed a headless
Service with a hand-maintained EndpointSlice. Both halves were wrong, and the real blocker is
elsewhere and harder.

Each route is written by
[`patch-pomerium-route.py`](../../ansible/roles/phys_kaas_tenant/files/patch-pomerium-route.py):

```yaml
- from: https://k8s-<tenant>.<domain>
  to: https://172.18.200.1:6443
  tls_custom_ca: <inline base64 PEM>
  kubernetes_service_account_token: <inline JWT>
  allowed_users: [...]
  allow_spdy: true
  allow_websockets: true
  timeout: 120s
```

**The upstream is not a problem.** `172.18.200.1` is not an external address — it is the
LoadBalancer IP of `kaas-capi/tenant-a`, the Service Kamaji already creates for the tenant control
plane, carrying selector `kamaji.clastix.io/name=tenant-a`. Because it *has* a selector, Kubernetes
maintains its EndpointSlice automatically (`tenant-a-hj8qj`, ownerRef `Service`, pointing at the two
apiserver pods). A hand-maintained EndpointSlice is only ever needed for a **selector-less** Service
fronting something genuinely outside the cluster, which this is not. So the route is an ordinary
Ingress in `kaas-capi` naming that Service — no new objects.

TLS also lines up: the controller sets `TlsServerName` to `<svc>.<ns>.svc.cluster.local` for a
`secure_upstream` route resolved via endpoints, and the tenant apiserver certificate carries
`DNS:tenant-a.kaas-capi.svc.cluster.local` among its SANs. So `secure_upstream` plus
`tls_custom_ca_secret` verifies, with no `tls_skip_verify` and no explicit `tls_server_name`.

**The blocker is `kubernetes_service_account_token`, and it is an upstream gap.**

- There is **no plain `kubernetes_service_account_token` annotation**. `baseAnnotations` in
  `pomerium/ingress_annotations.go` is a hand-written allow-list, the key is not in it, and an
  unrecognised key is a hard error (`unknown ingress.pomerium.io/<k>`). This is deliberate: upstream
  issue **#188** asked for exactly that annotation and was closed by generalising to the
  Secret-reference form instead, with the maintainers noting `_file`-style fields "exist for
  historical reasons only".
- The Secret form, `kubernetes_service_account_token_secret`, **strictly enforces** Secret type
  `kubernetes.io/service-account-token`:
  `if secret.Type != handler.expectedType { return error }`.
- Kubernetes will not let that type hold a **foreign** token. Verified on the lab: without the
  `kubernetes.io/service-account.name` annotation the API rejects the Secret outright
  (`Required value`); with an annotation naming a non-existent local ServiceAccount it is created and
  then **deleted within 8 seconds** by the token controller.
- And the token *is* foreign: `phys_kaas_tenant` reads it from the **tenant** cluster
  (`kube-system/pomerium-token`, via the tenant admin kubeconfig), not the management cluster.
- The Gateway API path is not an escape hatch either — `pomerium/gateway/` contains **no** reference
  to service-account tokens.

**Why the obvious workaround is not equivalent.** A static `Authorization: Bearer <token>` via
`set_request_headers_secret` (Opaque, no type constraint) would work mechanically. But Pomerium does
not merely forward that token — it authenticates *as* the service account and **impersonates the end
user**. The tenant cluster grants exactly that: ClusterRole `pomerium-impersonation`, verbs
`impersonate` on `users` and `groups`, bound to the tenant-side `pomerium` ServiceAccount. A static
header collapses every tenant user into that one service account, destroying per-user RBAC and audit
*inside tenant clusters*. That is a security regression, not a cosmetic one, and it must not be taken
silently.

**So this is genuinely undecided**, and it gates the swap: cutting over without an answer would drop
tenant `kubectl` access. The candidates, none free:

1. **Tenant apiserver OIDC** — configure the tenant control planes to trust Dex directly, so users
   authenticate as themselves and the shared service account disappears entirely. Architecturally the
   cleanest (it removes a shared credential rather than relocating it), but it changes the kubectl UX
   to an OIDC-capable kubeconfig. **← CHOSEN; see §9.**
2. **Federate the token** — make tenant apiservers trust the management cluster's service-account
   issuer, so a *local* ServiceAccount satisfies the Secret type. Preserves impersonation; a larger
   change to tenant control-plane configuration than the cutover itself.
3. **Upstream patch** — relax the type check to accept an Opaque Secret carrying a `token` key. It is
   a small change, and is literally the inverse of issue **#335** (which asked for the type check to
   be loosened in the other direction, and was resolved by swapping the required type rather than
   dropping the check). Needs upstream acceptance and a release.
4. **Static Authorization header** — fastest, and forfeits per-user identity as described above.

Owner either way: `phys_kaas_tenant` / `components/tenancy/cluster-chart`.

### 7.6 · `route-sync` is already suspended — the premise has moved

Checked on the lab: `route-sync` has **`suspend: true`**, last successful run **2026-07-26**, i.e. it
has not written anything for 13 days. The live `pomerium-config` was last modified **2026-07-29 by
`kubectl-patch`**. The real writers today are `phys_identity` (initial render), and the two Python
patchers in `phys_kaas_tenant` and `phys_headlamp` — both of which patch **`pomerium-base` *and*
`pomerium-config`**, precisely because route-sync would otherwise clobber their routes.
`patch-pomerium-route.py`'s own docstring says so: *"While route-sync is suspended on phys, both must
be patched."*

So the accurate count is **four writers, not two** — and the periodic one is not among the live ones.
This does not weaken the ADR; it strengthens it (an unmanaged blob accreted two more ad-hoc writers).
But it changes two things:

- **The §"hostile after the swap" hazard is latent, not active.** route-sync cannot restart the new
  Pomerium every 2 minutes while suspended. Keep the atomic-suspend instruction — it costs nothing and
  guards against someone unsuspending — but it is no longer the thing most likely to go wrong.
- **Step 6's deletion list is incomplete.** It must also remove
  **`pomerium-base.yaml.j2`** and both Python patchers, whose routes become Ingresses (§7.5). Deleting
  only `config.yaml.j2` leaves two writers of a ConfigMap nothing reads.

### 7.7 · Deployment-shape changes the plan does not mention

From the v0.33.1 bundled manifest:

- The CRD instance **must be named `global`** (`--pomerium-config=global`).
- Status is published from a Service named **`pomerium-proxy`**, not `pomerium` — so the
  `lbipam.cilium.io/ips` annotation that pins the ingress LB IP must move to it. Getting this wrong
  moves the public IP, which is the one failure the lab cannot recover from remotely.
- The **Deployment keeps the name `pomerium`**, which is exactly why route-sync's
  `rollout restart deploy/pomerium` would hit the new access plane.
- The pod is `readOnlyRootFilesystem: true`, non-root `65532`, with no PVC. Session storage becomes
  `spec.storage`, whose default is **in-memory** and documented as "not recommended for production" —
  an unchosen default that logs out every user on restart. Decide it explicitly.
- The bundled Service has **no SSH port**; 2222 must be added to the container, the Service and the
  provider forward alongside `--ssh-addr`.

### 7.8 · Revised order of work

1. Fix the `vm-chart` ssh Ingress path (§7.2) — it is inert today and cheap to correct now.
2. Build the prerequisites, all inert: the four ssh-auth Secrets (carrying `user_ca` across
   unchanged), the `spec.secrets` bootstrap Secret, the IdP client Secret, the LE staging and
   production ClusterIssuers, and the explicit `authenticate.<domain>` certificate.
3. Author the `Pomerium` CRD instance named `global`, and the base-route Ingresses — `id`, apex,
   `vms`, `perses`, `hubble`, `clusters` — each owned by the component that owns the workload.
4. Resolve the KaaS tenant-token blocker (§7.5) — it has no configuration-only answer, and the swap
   drops tenant kubectl access until it is settled.
5. Then swap, with the Service/port/LB-IP changes of §7.7 in the same action.

---

## 8 · Decided: session storage is PostgreSQL, provisioned by CloudNativePG

§7.7 flagged `spec.storage` as an **unchosen default** rather than a transcription: the bundled
controller manifest carries no storage configuration, and Pomerium's own default is in-memory, which
its documentation calls *"not recommended for production"*. Left alone it would have been adopted by
silence — the same way the chart registry ran without persistence for 8 days.

**Decision: PostgreSQL, one cluster per Kubernetes cluster, provisioned by
[CloudNativePG](https://cloudnative-pg.io), 3 instances on `ceph-block`.**

### Why not the two cheaper options

- **In-memory** loses every session on every Pomerium restart. That is not a rare event in this
  design: the controller rolls the Deployment on configuration change, and the migration itself will
  restart it repeatedly. "Everyone is logged out again" would be indistinguishable from the access
  plane being broken, which is precisely the confusion this ADR exists to reduce.
- **`storage.file`** trades that for a worse constraint. It needs an RWO PVC, which pins Pomerium to
  one replica on one node with `strategy: Recreate` — exactly the shape being removed with the
  autocert PVC (§7.7) — and it does not survive the loss of that node. It also sits awkwardly with
  the bundled pod's `readOnlyRootFilesystem: true`.

### Why this is not a new architectural bet

[`disaster-recovery.md`](disaster-recovery.md) §3.4 already specifies **"Databroker: Postgres per
cluster"** — with the explicit caveat that the docs say *don't* share one database across instances —
and §3.5 concludes that the production IdP decision "dictates the Postgres-replication build that the
whole access plane depends on". So Postgres under the access plane is a direction already chosen;
this step executes it rather than opening it. Choosing in-memory now would mean building the DR story
against a datastore the DR document does not assume.

CloudNativePG is the operator because it is CNCF, Kubernetes-native, helm-installable like every
other platform component here, and backs up to S3 — and Garage is already running for Velero, so the
backup target exists. Three instances because this is the access plane's session store: if it is
down, logins fail cluster-wide, and the rest of this control plane is already run three ways
(3 control-plane nodes, 3-way Ceph).

### The join is not plug-and-play

Verified against both sides rather than assumed:

- Pomerium's storage Secret must contain a key named exactly **`connection`** —
  `StorageSecrets.Validate()` fails with *"storage secret %s should have %q key"* on anything else.
- CloudNativePG generates `<cluster>-app`, of type `basic-auth`, with keys `username`, `password`,
  `host`, `port`, `dbname`, `uri`, `jdbc-uri`, `fqdn-uri`, `pgpass` — a ready-to-use DSN, but under
  `uri`, not `connection`.

So a derived Secret is needed, the same pattern as the ssh-auth and bootstrap Secrets (§7.1): read
CNPG's generated value, write it under the key Pomerium demands, and re-derive idempotently. The
same caveat applies — if CNPG rotates the application password, the derived Secret must be
re-derived, so it is written to be safe to re-run rather than created once.

`storage.postgres` also takes optional `tlsSecret` and `caSecret`. CNPG issues its own server
certificates, so wiring the CA is possible later; it is not a prerequisite for the swap and is left
out of the first cut deliberately rather than silently.

### What this costs, stated plainly

It adds a **hard dependency and a new failure domain** to the access plane: Pomerium with no reachable
database does not serve sessions. That is a real regression against in-memory, which has no
dependencies at all — the trade is that in-memory fails *constantly and by design*, while Postgres
fails rarely and recoverably. Three instances, `ceph-block` replication and S3 backups are what make
that trade defensible; a single instance would not, which is why it was rejected.

It is also a new component to operate, patch and back up. That cost is accepted here because the DR
plan already requires Postgres under this plane, so the alternative is not "no Postgres" but
"Postgres later, after building a DR story around something else".

---

## 9 · Decided: tenant clusters authenticate users directly, via OIDC

§7.5 established that the KaaS `k8s-<tenant>` routes cannot be ported to Ingress mode as they stand,
because Pomerium's `kubernetes_service_account_token_secret` requires a Secret type Kubernetes binds
to a *local* ServiceAccount, and the token in question is minted inside the **tenant** cluster. Of the
four candidates recorded there, **option 1 is chosen: configure tenant apiservers to trust Dex
directly.**

**The shared service account disappears rather than moving.** Today every tenant user reaches the
tenant apiserver as one `pomerium` ServiceAccount, with Pomerium impersonating them
(ClusterRole `pomerium-impersonation`, `impersonate` on `users` and `groups`). Under OIDC each user
authenticates *as themselves*, so per-user RBAC and audit inside tenant clusters stop depending on an
impersonation grant and a long-lived, non-expiring legacy token replicated into a ConfigMap. That is
better than what the migration was trying to preserve, not merely equivalent — which is why this was
preferred over federating the token (option 2) or patching upstream (option 3).

### Verified feasible before deciding

- **Kamaji can pass the flags.** `TenantControlPlane.spec.controlPlane.deployment.extraArgs.apiServer`
  is a `[]string`. tenant-a currently has no `--oidc-*` flags.
- **A pod can reach the issuer.** Probed from inside the cluster: `id.<domain>` resolves to the
  floating IP via the CoreDNS template, the discovery document fetched in **4.5 s**, and **TLS
  verified against system roots** — so no `--oidc-ca-file` is needed. The advertised issuer is exactly
  `https://id.<domain>/dex`, which is what `--oidc-issuer-url` must match.
- **The route can be a transparent proxy.** `bearer_token_format` is a per-route annotation, and
  `default` means *"pass bearer tokens to upstream applications without interpreting them"* — the
  `idp_*` modes consume them instead. So kubectl's own token reaches the apiserver untouched.

### Shape

- **Dex** gains a public `kubernetes` static client for the kubectl OIDC flow.
- **Tenant apiserver** gets `--oidc-issuer-url=https://id.<domain>/dex`,
  `--oidc-client-id=kubernetes`, `--oidc-username-claim=email`, `--oidc-groups-claim=groups`.
- **The route** becomes an ordinary Ingress in `kaas-capi` naming the `tenant-a` Service:
  `secure_upstream`, `tls_custom_ca_secret`, `allow_spdy`, `allow_websockets`, `timeout: 120s`,
  plus `bearer_token_format: default` and `allow_public_unauthenticated_access`.
- **Tenant RBAC** binds the user's email to a role, replacing the impersonation grant.

Removed once proven: the tenant-side `pomerium` ServiceAccount and its `pomerium-impersonation`
ClusterRole, and `patch-pomerium-route.py` — one of the four writers of `pomerium-config` (§7.6).

### Costs, stated rather than buried

- **Pomerium stops gating this route.** `allow_public_unauthenticated_access` means the IAP no longer
  stands in front of the tenant apiserver; the apiserver authenticates every request itself and
  returns 401 otherwise. This is the normal way a kube-apiserver is exposed, and per-user identity is
  a net gain — but it is honestly one fewer layer, and should be recorded as such rather than
  presented as a pure improvement.
- **The kubectl UX changes.** Users need an OIDC-capable kubeconfig (an `oidc-login`/kubelogin exec
  credential plugin) instead of today's flow. Headlamp is unaffected: `cluster-sync` merges the
  client-certificate admin kubeconfigs and does not use this path.
- **OIDC discovery hairpins through the public floating IP.** CoreDNS answers `*.<domain>` with the
  floating IP, so the apiserver's back-channel to Dex leaves and re-enters via the same provider
  forward whose flakiness caused the Let's Encrypt lockout (§3b). It works today — measured above —
  but it is a dependency worth removing by answering that name with the **internal** ingress LB IP
  instead, so the back-channel never leaves the cluster. Not yet tested, and deliberately not bundled
  into this decision.
- **A tenant apiserver restart** is required to add the flags, and the OIDC issuer must be reachable
  at apiserver start or authentication fails for everyone on that tenant.

### 9.1 · Blocker found on the lab: no node can pull an image

Attempting the first half of §9 on `rocky-phys` surfaced something that gates the **entire cutover**,
not just this decision: **the cluster nodes cannot pull container images from any public registry.**

| registry | result from a node |
|---|---|
| `ghcr.io` | `dial tcp 140.82.121.34:443: i/o timeout` |
| `docker.io` | pull fails (verified twice, different images) |
| `registry.k8s.io` | `lookup europe-north1-docker.pkg.dev … server misbehaving` |

Everything currently running does so from images cached on the node that happens to host it. The
symptom is invisible until something is rescheduled — which is exactly what a migration does.

**This is a hard prerequisite for step 4.** The swap replaces the Pomerium Deployment with
`pomerium/ingress-controller:v0.33.1`, which is cached **nowhere**. Attempted today, the new pod goes
`ImagePullBackOff` and the access plane is down — with rollback only possible onto the one node that
still has `pomerium/pomerium:v0.33.0` cached. That is precisely the unrecoverable-remotely scenario
§4 warns about, arrived at by a route nobody had modelled.

The fix is already this repo's documented pattern and needs no new machinery: the **gateway can reach
docker.io** (verified — `registry-1.docker.io` answers `401`, the expected anonymous-auth challenge),
and a local pushable registry already exists on `:5010`, mapped into Talos as `talu.registry`, holding
`talu-apiserver`. So the ingress-controller image must be mirrored there and the swap must reference
the mirrored name — **before** step 4, not during it.

Encountered en route: enabling OIDC restarts the tenant control plane, and a tenant apiserver
rescheduled onto a node without `registry.k8s.io/kube-apiserver:v1.34.1` cached would fail the same
way. So the tenant-side half of §9 is deliberately **not** applied until the mirror exists — proving
half a decision by degrading a live tenant control plane is not a trade worth making.
