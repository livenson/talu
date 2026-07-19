# Integrating an external orchestrator with Talu

Talu is **API-first and orchestrator-agnostic**. Any external billing/management/portal/automation
system drives Talu through a stable contract — there is no proprietary control API, and Talu also
runs with **no orchestrator at all**. Examples of systems that consume this contract: a billing/portal
platform such as **[Waldur](https://waldur.com)**, an internal self-service portal, or a CI/CD
pipeline. Nothing in Talu assumes any specific one.

The runtime picture with a sequence diagram is in
[`../architecture/flows.md`](../architecture/flows.md#the-integration-contract); the detailed seam
spec is [`../architecture/integrations.md`](../architecture/integrations.md). This page is the
integrator's summary.

## The contract — four verbs

1. **Write** labelled Kubernetes objects. The idiomatic tenant unit is a **`HelmRelease`** referencing
   the `talu-tenant` chart (which renders the namespace, ResourceQuota, RBAC, cloud-init Secret,
   `VirtualMachine`s, ssh `Service`, and `CiliumNetworkPolicy` security groups). You can also write the
   lower-level objects directly. **`talu.io/project-uuid` on every object is the join key** — never
   parse names.
2. **Watch** object status — the only progress/health signal: `HelmRelease` `Ready`, `VMI` conditions,
   route readiness. One `HelmRelease.status` summarizes a whole tenant. Names are handles; labels are truth.
3. **Read** the Prometheus HTTP API for usage — the per-namespace PromQL set (the same queries that
   render tenant dashboards are what you invoice).
4. **Delegate** identity to the shared **OIDC IdP** (generic — Dex/Keycloak/ZITADEL) and express
   authorization as **group membership** (a per-project group). Talu consumes the OIDC claims; it never
   calls back to the orchestrator.

## Producing tenants

A tenant is one **`HelmRelease`** applied directly to the Kubernetes API — Flux's helm-controller
renders the `talu-tenant` chart into the full bundle; deleting the `HelmRelease` garbage-collects the
tenant. The **chart's `values.schema.json` is the API surface**. The standalone (orchestrator-free) way
is the same object, either applied directly or committed under `environments/<site>/tenants/` and
reconciled from Git — so an orchestrator *adopts* Git-managed tenants rather than migrating them.
See [`../architecture/flows.md`](../architecture/flows.md#tenant--vm-provisioning).

## Identity, secrets, SSH, console — where to look

| Concern | Mechanism | Reference |
|---|---|---|
| Human login | OIDC → generic IdP; group claims drive policy | `integrations.md` §1 |
| Guest secrets | cloud-init from a Kubernetes `Secret` (`cloudInitNoCloud.secretRef`) | §2 |
| Shell access | Pomerium **Native SSH** — Pomerium is the SSH proxy + User CA; short-lived certs, no public :22 | §3 |
| VM console | virt-api VNC subresource via a per-tenant ServiceAccount | §5 |
| Usage → billing | Prometheus HTTP API, per-namespace recording rules | §7 |

## What a consumer must NOT assume

- No imperative side channels; **declarative objects only** — write, then watch `.status`.
- **Labels are truth, names are handles** — join on `talu.io/project-uuid`.
- Talu may run with **no orchestrator at all** — never design objects that require one to exist.
