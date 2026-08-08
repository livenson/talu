# portal — the route landing page (optional, lab/demo)

A read-only landing page served on the **apex** `https://<domain>/` that lists **every route Pomerium
exposes** and who's allowed. It's the friendly "what's here?" index for a lab or demo cluster.

**Not deployed by default.** Opt-in:

```sh
kubectl apply -k components/platform/portal          # deploys the portal into the pomerium namespace
dev/lab/expose-vm.sh <vm> <ns>                        # re-render routes -> the apex route appears
# (or wait for the route-sync CronJob; the apex route registers via the talu.io/landing-expose label)
```

## How it works — no drift, no dependencies

The page is generated on every request from whatever currently defines the routes, so it never drifts.
**Where that is depends on the migration** ([`adr-pomerium-ingress.md`](../../../docs/architecture/adr-pomerium-ingress.md)),
so the source is an explicit setting — `TALU_ROUTE_SOURCE` on the Deployment:

| value | routes come from | when |
|---|---|---|
| `config` *(default)* | the live **`pomerium-config`** ConfigMap, mounted read-only | before the swap |
| `ingress` | **`Ingress` objects** whose `ingressClassName` is the Pomerium class | after the swap |

**Flip it in the same change that sets `ingress.enabled` and suspends `route-sync` — not before, and
not after.** After the swap `pomerium-config` is *orphaned but still present*, so a portal left on
`config` keeps rendering a stale route list forever: showing routes that no longer exist, hiding every
new one, and looking perfectly healthy while doing it. The switch is deliberately manual because
auto-detection would guess wrong in exactly that window — the Ingress objects are created *before* the
swap and sit inert until a controller claims them. The rendered page names its own source in the
subtitle, so "which mechanism is serving this?" is answerable at a glance.

- `portal.py` is a stdlib-only HTTP server (no YAML lib, no writable filesystem, no egress). It parses
  with small targeted parsers and degrades to "no routes" rather than crashing if a shape surprises it.
- **Cluster access:** `config` mode uses none. `ingress` mode needs read-only `get/list/watch` on
  Ingresses ([`rbac.yaml`](rbac.yaml)) — there is no blob left to mount, so listing them is the only way
  to know what is exposed. It is far weaker than the renderer it replaces: no write verb anywhere, one
  resource type, and nothing it can read that the page does not already publish.
- The **site domain** comes from the `talu-platform` ConfigMap (the single source both route writers
  read, lab-notes #40), mounted at `/platform/domain`. In `ingress` mode there is no
  `authenticate_service_url` left to recover it from.
- It **self-registers** its route: today via the `talu.io/landing-expose: "true"` Service label; after
  the swap the apex route is an Ingress owned by the `phys_portal` role. Either way, delete the
  component and the route goes with it.

## Access

Public read (`allow_public_unauthenticated_access`) — anyone can see the route **directory** (names,
URLs, who's allowed). Opening any listed service still goes through Pomerium auth as normal; SSH routes
use Native SSH (`ssh <principal>@<vm>@ssh.<domain> -p 2222`; the old OpenStack lab forwarded `:23`).
To make the directory itself admin-only, drop `allow_public_unauthenticated_access` from the apex route
and give it a policy instead — in `ingress` mode that is the `pr_public` flag on the `phys_portal`
route, not a block in a renderer.

## Adding a description for a new platform route

Descriptions live in the `PLATFORM` map in `portal.py` (keyed on the route's sub-domain). Unmapped
routes still render — they just show their upstream as the description — so nothing is ever hidden.

Two sub-domain shapes get their own sections instead: `<ns>-dashboard` (per-tenant Perses) and
`k8s-<tenant>` (a managed cluster's kube-apiserver). The latter renders as a **non-link** — it is a
kubectl endpoint reached with an OIDC kubeconfig, not a page to open in a browser (§9).
