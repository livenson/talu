# identity

**Responsibility:** Keycloak (default IdP) behind a generic-OIDC + IdP-swap interface (authentik/Kanidm/ZITADEL as values).

**Upstream:** [Keycloak](https://www.keycloak.org/documentation) (production default) · [Dex](https://dexidp.io/docs/) (the lab's tiny OIDC IdP).

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
