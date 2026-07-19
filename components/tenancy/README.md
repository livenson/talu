# tenancy

**Responsibility:** Talu's native, orchestrator-agnostic tenant API. The `tenant-chart`
renders the full namespace bundle (namespace, ResourceQuota, scoped RBAC, per-VM
cloud-init Secret, ssh Service, CiliumNetworkPolicy pinning + security groups) plus
the VMs, from a values file. SSH is Pomerium Native SSH (no OpenBao). **Every object
carries the `talu.io/project-uuid` label** — the join key for any external orchestrator.

A tenant or VM is a values-PR under `environments/<site>/tenants/`. This is the
Phase-9a operating mode and stays first-class forever; an external orchestrator (and any other
portal) is an *external* consumer of the objects this chart produces — see
`docs/integrations/`.
