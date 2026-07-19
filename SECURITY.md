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
- **Bake capabilities, inject identity.** Golden images are generic; per-tenant identity and
  secrets arrive at boot via cloud-init sourced from a Kubernetes `Secret` (not baked into the
  image or the VM manifest). SSH uses Pomerium **Native SSH** — short-lived certificates issued
  after OIDC, no static credentials anywhere.
- **One policy-controlled front door.** All inbound human/tunneled traffic enters via
  Pomerium; Cilium pins the tenant path to the proxy in eBPF (non-bypassable).
- **One identity vocabulary.** OIDC identity = Pomerium subject = SSH cert principal
  across all audit logs.

The end-to-end access plane (identity, guest secrets, Pomerium Native SSH, tenant isolation) is
documented in [`docs/architecture/flows.md`](docs/architecture/flows.md) and
[`docs/integrations/`](docs/integrations/). The security acceptance test is the pilot's exit
criterion — see `docs/development/validation-plan.md`, Stage 6.
