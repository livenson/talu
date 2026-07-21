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

## Deploying

Ansible: `ansible-playbook site.yml --tags logging` (role `logging` — helm-installs Loki + Alloy, then
applies the Perses Loki datasource + audit dashboard). Runs after `monitoring` (the Perses server + the
Loki datasource's target live there).

## Retention & long-term audit

14-day retention on the lab (filesystem). For a compliance-grade trail, raise
`limits_config.retention_period`, move Loki to object storage, and/or forward the `authorize check`
stream to an external SIEM — the collection point is the same.
