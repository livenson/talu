# Architecture — what Talu is and why

Settled decisions. Treat these as fixed unless a task explicitly reopens them.

- [`platform-context.md`](platform-context.md) — the system, every architectural decision
  with its rationale, the design rules, naming contract, capacity model, environments.
- [`integrations.md`](integrations.md) — the component-to-component seams: identity, secrets,
  SSH chain, access plane, console, metrics→billing, upgrades, and the external-manager
  contract (§10). The implementation/review contract.
- [`single-node-pilot-plan.md`](single-node-pilot-plan.md) — the 9-phase build order and the
  1→3→N scaling story.

Integrator-facing summary of §10 lives in [`../integrations/`](../integrations/).
