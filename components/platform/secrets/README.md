# secrets

**Responsibility:** OpenBao — per-tenant namespaces, SSH CA, AppRole + response-wrapping machine bootstrap.

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
