# secrets

**Responsibility:** OpenBao — dynamic non-SSH secrets (DB creds, API tokens), AppRole +
response-wrapping machine bootstrap, per-tenant namespaces.

> **Note (2026-07):** OpenBao is **not** used for VM SSH or for delivering guest secrets.
> - **SSH access** is **Pomerium Native SSH** — Pomerium is the SSH proxy *and* SSH User CA
>   (see `../access/`). This replaced the OpenBao SSH-CA that earlier lab builds used.
> - **Guest secrets** ride into the VM via cloud-init sourced from a Kubernetes Secret
>   (KubeVirt `cloudInitNoCloud.secretRef`) — no guest agent, no OpenBao.
>
> OpenBao remains the intended home for **dynamic, short-lived non-SSH secrets** with TTL/rotation
> (the §2.2 wrapped-token AppRole bootstrap). It is **deferred** — not deployed on the lab — until a
> concrete need for dynamic secrets exists. Production Raft storage + unseal, not dev mode.

This is a reusable base — part of `components/` (the product). Adopters do **not**
edit it; site-specific values live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.
