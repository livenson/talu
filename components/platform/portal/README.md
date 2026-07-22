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

- The routes come from the **live `pomerium-config`** ConfigMap (the same one `dev/lab/expose-vm.sh` /
  `components/tenancy/flux/route-sync.yaml` render), **mounted read-only**. The page is generated from it
  on every request, so it always matches exactly what's exposed — platform routes *and* per-tenant
  `ssh://<vm>` and `<ns>-dashboard` routes — including each route's allow-list.
- `portal.py` is a ~120-line stdlib-only HTTP server (no YAML lib, no cluster API, no writable
  filesystem, no egress). It parses the config with a small targeted parser and degrades to "no routes"
  rather than crashing if the shape ever surprises it.
- It **self-registers** its route: the `talu.io/landing-expose: "true"` Service label is what the route
  renderer turns into the public apex route. Delete the component → the label is gone → the route
  disappears on the next render. Genuinely optional.

## Access

Public read (`allow_public_unauthenticated_access`) — anyone can see the route **directory** (names,
URLs, who's allowed). Opening any listed service still goes through Pomerium auth as normal; SSH routes
use Native SSH (`ssh <principal>@<vm>@ssh.<domain> -p 23`). To make the directory itself admin-only,
change the landing block in the renderer to `allowed_users` instead of public.

## Adding a description for a new platform route

Descriptions live in the `PLATFORM` map in `portal.py` (keyed on the route's sub-domain). Unmapped
routes still render — they just show their upstream as the description — so nothing is ever hidden.
