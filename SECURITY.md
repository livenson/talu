# Security Policy

## Reporting a vulnerability

Please report security issues **privately** to the maintainers (see MAINTAINERS.md) —
do not open a public issue for an undisclosed vulnerability. We aim to acknowledge within
a few working days and will coordinate a fix and disclosure timeline with you.

## Security posture (context for reviewers)

Talu makes several structural security choices; changes that weaken them need explicit
justification:

- **The platform never acts inside tenant guests.** No `guest-exec` via qemu-guest-agent
  for management; agent updates arrive via the platform APT repo + unattended-upgrades.
- **Bake capabilities, inject identity.** No secret, token, or per-tenant material is ever
  baked into an image or left etcd-resident in cloud-init. Machine identity bootstraps via
  single-use response-wrapped OpenBao tokens.
- **One policy-controlled front door.** All inbound human/tunneled traffic enters via
  Pomerium; Cilium pins the tenant path to the proxy in eBPF (non-bypassable).
- **One identity vocabulary.** Keycloak username = Pomerium subject = SSH cert principal
  across all audit logs.

The end-to-end integration seams (identity, secrets, SSH CA, access plane) are specified in
`docs/architecture/integrations.md`. The security acceptance test is the pilot's exit
criterion — see `docs/development/rocky9-validation-plan.md`, Stage 6.
