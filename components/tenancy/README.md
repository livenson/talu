# tenancy

**Responsibility:** Talu's native, manager-agnostic tenant API. The `tenant-chart`
renders the full namespace bundle (namespace, ResourceQuota, LimitRange,
CiliumNetworkPolicy, RBAC + per-tenant ServiceAccount, OpenBao roles, Keycloak
groups) plus VM objects from a values file. **Every object carries the
`talu.io/project-uuid` label** — the join key for any external manager.

A tenant or VM is a values-PR under `environments/<site>/tenants/`. This is the
Phase-9a operating mode and stays first-class forever; Waldur (and any other
portal) is an *external* consumer of the objects this chart produces — see
`docs/integrations/`.
