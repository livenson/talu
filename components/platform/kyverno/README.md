# kyverno

**Responsibility:** admission/policy engine — validates Talu's multi-tenant invariants and verifies
image signatures at admission. This component installs the **engine** that
[`access/kyverno-guardrails.yaml`](../access/kyverno-guardrails.yaml) and the policies under
`policies/` depend on. Doctrine: **Kyverno enforces invariants, it does not generate** — the tenant
chart is the single generator (see [`access/README.md`](../access/README.md)).

**Upstream:** <https://kyverno.io/docs/> · CNCF Graduated.

This is a reusable base — part of `components/` (the product). Adopters do **not** edit it;
site-specific values live in `environments/<site>/`. See `docs/customize/` for the boundary.

## Policies (all ship **Audit** — observe first)

| Policy | Invariant |
|---|---|
| `require-project-uuid` | Tenant `VirtualMachine`s must carry `talu.io/project-uuid`. |
| `restrict-privileged` | No privileged tenant container pods (platform ns + virt-launcher exempt). |
| `verify-images-cosign` | cosign signature check on Talu-registry images (Pods + CDI DataVolumes). |

Audit findings surface as PolicyReports: `kubectl get polr -A`. Nothing is blocked in Audit.

## Promoting to Enforce

Base policies are Audit. Flip per-environment (the `security.kyverno.enforce` knob in the env
`values.yaml` is the human-facing summary; the mechanism is a small kustomize patch in the overlay
that sets `validationFailureAction: Enforce` / per-rule `failureAction: Enforce`). Do this only after
watching PolicyReports confirm no legitimate workload trips a policy.

## Dependency — cosign key

`verify-images-cosign.yaml` ships a **placeholder** public key. Wire the real CI signing key
(`ci/image-build.sh` signs with cosign) via the environment overlay before promoting that rule to
Enforce, and set the `imageReferences` to your registry host.
