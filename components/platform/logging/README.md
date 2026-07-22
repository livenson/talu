# logging

**Responsibility:** the **audit tier** — *who accessed what, when*. Metrics (the monitoring component)
answer *how much / where / allowed-or-denied*; they deliberately omit user identity (cardinality).
The **identities live in Pomerium's access logs**, and this component collects, retains, and makes them
queryable — **in Perses, no Grafana** (Perses ships the Loki plugins).

## The pipeline

```
Pomerium pod logs ──(Alloy, via K8s API)──▶ Loki ──(LokiLogQuery)──▶ Perses "Access Audit" dashboard
```

- **Loki** (`loki-values.yaml`, chart `grafana/loki` SingleBinary + filesystem, 14-day retention) —
  the log store. Small/single-node for the lab; production swaps to object storage + scalable mode.
- **Grafana Alloy** (`alloy-values.yaml`, DaemonSet) — the collector. Reads pod logs via the
  **Kubernetes API** (`loki.source.kubernetes` — no hostPath, so the namespace stays PSA `baseline`),
  labels them `namespace/pod/container/node`, ships to Loki. The JSON is parsed at **query** time with
  LogQL `| json`, so ingest stays low-cardinality (email/path are NOT promoted to labels).
- **`loki-datasource.yaml`** — a Perses `LokiDatasource` (proxy to Loki, like the Prometheus one), so
  the browser only ever talks to Perses (reachable via Pomerium).
- **`dashboard-audit.yaml`** — the Perses **Access Audit** dashboard: requests-per-user
  (`LokiTimeSeriesQuery`), the who-accessed-what trail and denied attempts (`LokiLogQuery` +
  `LogsTable`). It appears in the **same Perses** as the metrics dashboards, at `perses.<domain>`
  (admin-only, via Pomerium) — no separate UI, no Grafana.

## Why Perses, not Grafana

Perses (v0.53+, CNCF) ships the `LokiDatasource`, `LokiLogQuery`, `LokiTimeSeriesQuery` and `LogsTable`
plugins built-in — verified on the deployed server. So the logs render natively alongside the metrics
dashboards, keeping **one dashboard layer**. (An earlier draft used Grafana before confirming Perses's
Loki support — it does.)

## The audit query (also works in Perses' Explore / any LogQL client)

```logql
{namespace="pomerium"} | json | message="authorize check" | email != ""
  | line_format "{{.email}}  {{.method}} {{.host}}{{.path}}  allow={{.allow}}"
```
→ `alice@talu.local  POST hubble.<domain>/api/control-stream  allow=true`

Denied attempts: `… | allow="false"`. Per-user rate:
`sum by (email) (rate({namespace="pomerium"} | json | email != "" [5m]))`.

Ingesting a VM's guest `sshd` logs the same way extends this to the full **SSH audit** (which user
cert-principal reached which VM).

## VM internal logs (what's happening *inside* the guests)

Beyond access audit, this component also collects the guests' own logs into the same Loki, as a
**separate, tenant-scoped index** (`namespace=<tenant>, vm=<name>`), viewable in Perses. Two tiers:

**Tier 1 — serial console (always on, zero guest trust).** Each VM streams its journal to the serial
console via a tiny `talu-console-logs.service` (cloud-init: `journalctl -b -f > /dev/console`). KubeVirt
captures the serial console into the virt-launcher pod's **`guest-console-log`** container, which Alloy
already scrapes. Alloy stamps the `vm` label **from the pod metadata** (`kubevirt.io/vm`), so the
tenant/VM labels are set by the platform and **cannot be forged by the guest**.
- `dashboard-vmlogs.yaml` — the operator **VM Logs** dashboard (`$namespace`+`$vm` pickers; volume /
  console / errors). The per-tenant equivalent ships with the tenant chart (`templates/dashboards.yaml`,
  a `vm-logs` dashboard hard-scoped to the tenant via a Loki `prom-label-proxy`).
- Gotchas (see lab-notes #33): (1) `guest-console-log` is a KubeVirt **native-sidecar initContainer**,
  not a regular container — but Alloy discovers and tails it. (2) An *idle* guest writes nothing to
  serial after boot — hence the journal-streaming service. (3) Write to **`/dev/console`, not
  `/dev/ttyS0`** (getty owns ttyS0), and use a **service, not journald `ForwardToConsole`** (racy under
  cloud-init). (4) Filter blank getty lines in dashboards with `|~ "\S"` or rows show only the VM prefix.
  Verify end-to-end by firing an external SSH at a VM and finding the `sshd` lines in Loki.

**Tier 2 — in-guest agent (opt-in, `logging.agent: true`).** For rich app logs (files + full journald),
a Fluent Bit baked into the golden image tails and **pushes to a per-tenant ingest gateway**, never to
Loki directly. The gateway (folded into the tenant chart, `templates/logging.yaml`) is the spoof
defense:

> **Why the guest can't spoof another tenant.** An in-guest agent is inside a VM the tenant controls, so
> any label it asserts is forgeable. We never trust it. Each tenant gets its **own** gateway, rendered
> with that tenant's **fixed slug** baked in; the gateway **hard-overwrites** `namespace=<slug>` on every
> received line (a `stage.static_labels` + `stage.label_keep` in Alloy). A `CiliumNetworkPolicy` lets
> **only that tenant's VM endpoints** reach that gateway. So the worst a malicious guest can do is
> mislabel its *own* logs within its *own* namespace — it can never write into another tenant's stream.
> *Validated on the lab:* a push carrying `namespace="evil-spoof-tenant"` through the gateway was stored
> as `namespace=acme, tier=guest-agent` — the spoofed value never appears in Loki.

**`loki-ingress-policy.yaml`** — defense-in-depth so a guest can't *bypass* its gateway and push straight
to Loki with a forged namespace. It's an allow-list (`fromEntities: [host, remote-node, health]` for the
kubelet readiness probe, plus the logging namespace, tenant gateways, and monitoring). **Not applied on
the nested Talos-in-Podman lab**: there the kubelet's `:3100/ready` probe isn't classified as `host`, so
any default-deny on Loki starves the probe and Loki drops out of its Service endpoints (see lab-notes).
On a normal cluster it's correct; the *primary* control (gateway hard-stamping, above) is enforced
everywhere. Production alternative: enable Loki `auth_enabled` + require `X-Scope-OrgID`.

## Deploying

Ansible: `ansible-playbook site.yml --tags logging` (role `logging` — helm-installs Loki + Alloy, then
applies the Perses Loki datasource + audit dashboard). Runs after `monitoring` (the Perses server + the
Loki datasource's target live there).

## Retention & long-term audit

14-day retention on the lab (filesystem). For a compliance-grade trail, raise
`limits_config.retention_period`, move Loki to object storage, and/or forward the `authorize check`
stream to an external SIEM — the collection point is the same.
