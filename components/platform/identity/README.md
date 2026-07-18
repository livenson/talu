# identity

**Responsibility:** Keycloak (default IdP) behind a generic-OIDC + IdP-swap interface (authentik/Kanidm/ZITADEL as values).

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
