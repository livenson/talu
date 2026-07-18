# monitoring

**Responsibility:** Prometheus + recording rules for the per-namespace billing PromQL set (the metrics half of the integration API).

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
