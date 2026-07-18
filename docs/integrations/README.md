# Integrating an external manager with Talu

Talu is **API-first and manager-agnostic**. Any external billing/management/portal platform
drives Talu through a stable contract — there is no proprietary control API. Waldur is the
*reference* implementation of this contract; **nothing in Talu assumes it specifically**.

The authoritative, detailed seam specification is
[`../architecture/integrations.md`](../architecture/integrations.md). This page is the
integrator's summary.

## The contract — four verbs

1. **Write** labelled Kubernetes objects — the tenant bundle (namespace, ResourceQuota,
   LimitRange, CiliumNetworkPolicy, RBAC + ServiceAccount, OpenBao roles), `DataVolume`s,
   `VirtualMachine`s, Pomerium route CRDs. **`talu.io/project-uuid` on every object is the
   join key** — never parse names.
2. **Watch** object status — the only progress/health signal: `DataVolume` phases, `VMI`
   conditions, route readiness. Names are handles; labels are truth.
3. **Read** the Prometheus HTTP API for usage — the per-namespace PromQL billing set (the
   same queries that render tenant dashboards are what you invoice).
4. **Delegate** identity to the shared OIDC realm (Keycloak by default) and express
   authorization as group membership (`waldur/{project_uuid}/{role}`).

## Producing tenants

The native, manager-free way to create a tenant is to render
`components/tenancy/tenant-chart` from a values file (a PR under
`environments/<site>/tenants/`). An external manager produces the **same objects** with the
same `talu.io/project-uuid` label — so it *adopts* Git-managed tenants rather than migrating
them. The chart is the object spec either way.

## Identity, secrets, SSH, console — where to look

| Concern | Mechanism | Reference |
|---|---|---|
| Human login | OIDC → Keycloak; group claims drive all policy | `integrations.md` §1 |
| Machine secrets | OpenBao AppRole + single-use response-wrapped token via cloud-init | §2 |
| Shell access | Per-tenant SSH CA, short-lived certs, Pomerium TCP tunnel (no public :22) | §3 |
| VM console | virt-api VNC subresource via a per-tenant ServiceAccount | §5 |
| Usage → billing | Prometheus HTTP API, per-namespace recording rules | §7 |

## What a manager must NOT assume

- No imperative side channels; declarative objects only.
- No standing access to tenant OpenBao namespaces (break-glass is a separate audited ceremony).
- Talu may run with **no manager at all** — don't design objects that require one to exist.
