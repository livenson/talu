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

1. ~~Confirm v0.33 supports the Ingress controller and `ssh_upstream`.~~ **Done (2026-08-08)** — see
   §4: SSH support predates v0.33 by a year, so no upgrade is a prerequisite.
2. Install the controller and its CRDs **alongside** the existing config. Nothing routes through it.
3. Migrate **one dashboard route** — lowest value at risk — and verify end to end.
4. Migrate the per-VM `ssh://` routes; `talu-vm` grows an `Ingress`.
5. Move the base routes into the `Pomerium` CRD.
6. Delete `route-sync`, its RBAC, and the `talu.io/*-expose` label contract.

Do **not** collapse steps 3–5: each is independently reversible, and the failure mode being avoided
(404 on every host, no console) is exactly what a big-bang cutover produces.
