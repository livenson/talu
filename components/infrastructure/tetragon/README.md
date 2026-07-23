# tetragon

**Responsibility:** eBPF runtime security observability + enforcement — process/file/network events
and in-kernel blocking via TracingPolicies. Pairs with the existing Cilium eBPF dataplane; the
foundation for a tenant-facing "runtime threat detection" tier.

**Upstream:** <https://tetragon.io/docs/> · CNCF (Cilium umbrella).

> ⚠️ **Real hardware only.** Tetragon needs kernel BTF and `/sys/kernel/tracing`. The nested
> Talos-in-Podman lab (`rocky-sandbox`) exposes neither — the same class of limitation as the
> rbd-nbd wall (lab-notes #14/#15). Tetragon is therefore wired into `environments/example` only and
> deliberately **omitted from `rocky-sandbox`**. Validate it on KVM-capable hardware.

This is a reusable base — part of `components/` (the product). Adopters do **not** edit it;
site-specific values live in `environments/<site>/`.

## What ships

- **Agent DaemonSet + operator** (Talos-tuned values: `enablePolicyFilter`, `enableProcessCred/Ns`,
  `/sys/kernel/tracing` hostPath). JSON events → stdout → **Grafana Alloy → Loki → Perses** (reuses
  the logging plane; no new export wiring).
- **TracingPolicies:**
  | Policy | Mode | What |
  |---|---|---|
  | `observe-ptrace-virt-launcher` | observe | ptrace against virt-launcher pods (injection signal). |
  | `observe-sensitive-files` | observe | reads of `/etc/shadow`, `/etc/kubernetes/`, kubelet PKI. |
  | `enforce-block-core-pattern` | **enforce** | Sigkill writes to `/proc/sys/kernel/core_pattern` (escape primitive); scoped to exclude tenant namespaces. |

## Safety of the enforcing policy

`enforce-block-core-pattern` is scoped by `podSelector` to pods **without** `talu.io/project-uuid`, so
it can never fire inside a tenant VM namespace. Prefer `action: Override` (deny, no kill) over
`Sigkill` if you want an even softer failure mode — see the comment in the policy file.
