# Development

- [`validation-plan.md`](validation-plan.md) — the no-KVM quick-mode: implement
  and validate the whole stack on one remote cloud VM. Start here.
- The remote-lab dev loop (`make lab-tunnel` / `lab-sync` / `lab-status`) is documented in the
  top-level [`README`](../../README.md).

The conventions that shape the codebase (values-not-structure, orchestrator-agnostic) are in
[`../../CLAUDE.md`](../../CLAUDE.md) and the customization boundary [`../customize/`](../customize/).
