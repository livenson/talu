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

One item this raises that is NOT a detail: Talu currently uses Pomerium **autocert** (Let's Encrypt),
and the CRD offers `certificates` (explicit TLS Secrets) and `certificateAutoProvision` (cert-manager)
instead. Given lab-notes records an hour-long **LE rate-limit lockout** from retrying against the prod
endpoint over a flaky forward, the cert path must be decided *before* the swap, not discovered during
it. cert-manager is already a platform component, so `certificateAutoProvision` is the likely answer.

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
- **Kustomize components** (monitoring, Cilium, identity) have no equivalent, so the base-route
  Ingresses need a decision: a kustomize `replacements` block sourced from the `talu-platform`
  ConfigMap, or the owning ansible role templating the host as it already templates other values.
  **Resolve this before writing those manifests** — it determines whether the base routes live in
  `components/` at all, or have to be role-rendered like the current `config.yaml`.

Getting it wrong reintroduces exactly what this ADR removes: a hostname that only one writer knows.

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
   `ingress.enabled: true`. Suspend `route-sync` in the same step — do **not** delete it yet.
   Rollback: redeploy the old Pomerium from `phys_identity`, unsuspend.
5. **Verify every route CLASS** before touching anything else: an ssh route, a tenant dashboard, each
   base route, the public apex. A 404 on one class is recoverable at that moment and much less so
   later.
6. **Then** delete `route-sync`, its RBAC, the `talu.io/*-expose` label contract, and
   `phys_identity`'s `config.yaml` template — in that order, once nothing depends on them.
