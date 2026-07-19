# Contributing to Talu

Thanks for your interest. Talu is developed in the open; this guide covers the
conventions that keep the codebase coherent.

## The two rules that shape everything

1. **Values, not structure.** Environments differ only in overlay *values*
   (`environments/`), never in structure (`components/`). An `if dev` branch in a
   component is a bug — the condition belongs in configuration. If you find yourself
   editing a base to make one site work, stop: the thing you're hardcoding is a value.
2. **Manager-agnostic.** Nothing in `components/` may assume Waldur (or any specific
   external manager). The integration surface is Kubernetes objects + the Prometheus
   HTTP API + the `talu.io/project-uuid` label. See `docs/integrations/`.

## Where changes go

- Reusable mechanism → `components/`. Site-specific value → `environments/<site>/`.
- New golden-image capability → `images/` (baked but disabled; identity injected at boot).
- Docs live beside the thing they describe; architecture decisions go in `docs/architecture/`.

## Development loop

Talu develops against a remote lab (see `docs/development/validation-plan.md`).
The fast loop is: edit → `make lab-sync` → `make lab-status`. Before opening a PR:

```sh
make kbuild        # every overlay must `kustomize build` cleanly (structure-integrity)
```

## Commits & PRs

- Keep commits focused; write imperative subject lines.
- CI runs the committed state only (local `lab-sync` accelerates the loop, never forks reality).
- The forge stays the source of truth; `environments/rocky-sandbox` is the e2e gate.

## Secrets

Never commit secrets. The repo ships `*.example` stubs only; real values are encrypted
with SOPS/age or come from OpenBao at runtime.

## License

By contributing you agree your contributions are licensed under Apache-2.0.
