# Customizing Talu — the boundary, and tracking upstream

Talu is built to be **cloned and adapted** to your own site without forking away from
upstream. This works because of one rule:

> **`components/` is the product — you clone it, you don't edit it.
> `environments/<site>/` is your config — you copy `example/` and edit only values.**

Because you only ever *add* an overlay and never touch a base, pulling a new Talu release
is a clean `git merge`.

## The adopter workflow

```sh
# 1. get Talu
git clone https://<forge>/<org>/talu.git && cd talu

# 2. create your site overlay from the reference
cp -r environments/example environments/acme

# 3. edit values only — never components/
$EDITOR environments/acme/values.yaml     # storage sizes, hostnames, IdP, replicas, IPAM mode...

# 4. point your Flux at environments/acme and reconcile
```

Keep `environments/acme/` and your secrets in **your own** repository or branch. The
upstream repo ships only `*.example` secret stubs; real values are encrypted with SOPS/age
— never committed. Guest secrets reach VMs as Kubernetes Secrets referenced by cloud-init.

## Tracking upstream

```sh
git remote add upstream https://github.com/<org>/talu.git
git fetch upstream --tags
git merge v0.4.0            # merges cleanly: you only added environments/acme/
```

If a merge ever conflicts inside `components/`, that's a signal you edited a base — move the
change into your overlay as a value, or propose it upstream.

## What is a "value" vs "structure"?

| Value (goes in `environments/`) | Structure (lives in `components/`) |
|---|---|
| replica counts, storage sizes, pool `size`/`failureDomain` | which components exist and how they wire together |
| hostnames, route policies, DNS scheme | the Pomerium/Cilium mechanism itself |
| IdP choice (Keycloak / authentik / Kanidm) behind the OIDC interface | the OIDC integration contract |
| `useEmulation`, guest arch, MTU, IPAM mode | KubeVirt/Cilium/Rook base manifests |
| tenant definitions (`tenants/*.yaml`) | the tenant chart that renders them |

If a component needs to behave differently per environment, the thing it branches on is a
**value** — surface it in `values.yaml`, don't branch in the base.

## Swappable pieces designed in

- **IdP**: Keycloak is the default, but every consumer speaks generic OIDC; the
  manager→IdP group-sync sits behind an interface, so authentik/Kanidm/ZITADEL is a values
  swap, not a rewrite.
- **External orchestrator**: Talu runs Git-first with no orchestrator. Any external system
  (e.g. Waldur, a self-service portal, a CI pipeline) is an external consumer of the contract in
  `docs/integrations/` — not something you configure inside `components/`.
