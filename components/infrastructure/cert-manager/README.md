# cert-manager

**Responsibility:** Internal CA ClusterIssuer; TLS for every platform service.

**Upstream:** <https://cert-manager.io/docs/>.

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
