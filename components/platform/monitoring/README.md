# monitoring

**Responsibility:** the metrics half of the integration contract — a Prometheus that scrapes the
substrate and emits the **per-namespace usage recording rules** an external orchestrator reads for
accounting (the § READ verb). Billing/€-conversion is *not* here — it lives in the orchestrator.

## What's in here

- **`helmrepository.yaml` / `helmrelease.yaml` / `values.yaml`** — `kube-prometheus-stack` (pinned
  `87.17.0`, app `v0.92.1`) **Prometheus-only**: Prometheus-operator + Prometheus + kube-state-metrics
  + node-exporter. Grafana is **off** (Perses is the dashboard layer, exposed via Pomerium — Phase 2);
  **Alertmanager is on** with a **null default receiver** (see Alerting below). Prometheus selects all
  ServiceMonitors/Rules cluster-wide, and the Talos/Cilium-inapplicable scrapers
  (etcd/scheduler/controller-manager/kube-proxy) are disabled. Upstream:
  <https://github.com/prometheus-community/helm-charts>.
- **`servicemonitors.yaml`** — scrape KubeVirt's `kubevirt-prometheus-metrics` (per-VMI
  `kubevirt_vmi_*`, over TLS). KSM + node-exporter ship their own from the chart.
- **`recording-rules.yaml`** — the `talu:tenant_*` usage set, every series keyed on `namespace`
  (== tenant slug), plus `talu:tenant_project_uuid:info` mapping namespace → project UUID. These are
  the READ-verb surface *and* the source for per-tenant dashboards (dashboards == invoices).
- **`namespace.yaml`** — the `monitoring` namespace, PSA **privileged** (node-exporter needs
  hostNetwork/hostPath under Talos' baseline enforcement).
- **`perses-helmrepository.yaml` / `perses-operator-helmrelease.yaml`** — the **perses-operator**
  (`0.4.0`), which manages a Perses server and syncs dashboard/datasource CRs into it (a namespace
  maps to a Perses *project*). Needs cert-manager (present in the access plane).
- **`perses-instance.yaml`** — the `Perses` server CR (`talu`, labelled `talu.io/perses=operator`) +
  a default `PersesDatasource` pointing at the in-cluster Prometheus.
- **Operator dashboards** (`PersesDashboard`, exposed **only through Pomerium** — a `perses.<domain>`
  route scoped to the admin group, no public endpoint):
  - `dashboard-fleet.yaml` — fleet overview (VMs / vCPU / memory / egress / quota per tenant; node CPU &
    memory; **golden-image freshness** ← `talu:image_outdated`).
  - `dashboard-netsec.yaml` — **Network & Security** (Cilium/Hubble policy verdicts, drops, L7).
  - `dashboard-backup.yaml` — **Backup & DR** (staleness per schedule, true per-tenant backup size,
    outcomes, restore drills, Garage capacity/health). Backed by `backup-rules.yaml` +
    `ksm-velero-crs.yaml`; see [`../../../docs/operations/backup-restore.md`](../../../docs/operations/backup-restore.md).
  - `dashboard-vmdetail.yaml` — **per-VM drill-down** with `$namespace`+`$vm` pickers (CPU / memory /
    disk throughput & IOPS / network from `kubevirt_vmi_*`).
  - `dashboard-pomerium.yaml` — **Access & Identity (Pomerium)**: request outcomes (allow/deny/error),
    authorization decisions, open connections (HTTP + Native-SSH sessions), and per-service request /
    error / latency / **traffic size by hostname** (from `pomerium_http_server_*`, which carry a `host`
    label — the Envoy cluster metrics only have opaque route-IDs). Needs `metrics_address :9902` on
    Pomerium + the `pomerium` ServiceMonitor (both in the `identity_pomerium` role + `servicemonitors.yaml`).
  - The **Access Audit (Pomerium)** dashboard — *who accessed what, when* — lives with the logging tier
    (`components/platform/logging/dashboard-audit.yaml`), rendered in this same Perses via a Loki
    datasource. Metrics answer *how much / where*; the audit (logs) answers *who*.
  - `dashboard-alerts.yaml` — **Alerts**: the primary "what's on fire now" view — a firing-alerts table
    plus severity/name/pending trends off the Prometheus `ALERTS` series. The Perses-native counterpart
    to the Alertmanager UI (which owns silences/notification).
  - `dashboard-certs.yaml` — **Certificates (PKI)**: days-to-expiry + next-renewal per cert, certificate
    and issuer/ClusterIssuer ready status (incl. the `talu-ca` root), and controller reconcile errors —
    off the cert-manager scrape. The visual companion to `TaluCertExpiringSoon`.
  - `dashboard-alertops.yaml` — **Alert Operations**: health of the alerting *pipeline* — active vs
    suppressed alerts, notifications sent/failed + latency, active silences, config-reload success, and
    the Prometheus→Alertmanager send-side. (Answers "is paging actually working", vs "what's firing".)
- **`resource-rules.yaml`** — platform health alerts (metrics all verified on the lab): cert expiry
  (`certmanager_*`, needs the cert-manager ServiceMonitor), tenant quota exhaustion (`kube_resourcequota`),
  KubeVirt component health + failed VMIs (`kubevirt_virt_*_ready_status`, `kubevirt_vmi_info`). PVC-full
  and Ceph-capacity alerts are intentionally absent — those metrics aren't scraped here yet (a scrape
  must come first; no dead rules).
- **`backup-rules.yaml`** — the `talu:backup_*` set (size, freshness, outcomes) + backup **and DR-drill**
  alerts (`TaluRestoreTestStale/Failed` off Velero's `velero_restore_*_total`; the drill itself is
  `components/platform/backup/restore-test.yaml`).
  **`ksm-velero-crs.yaml`** — kube-state-metrics CustomResourceState over the Velero CRs; it is the
  ONLY source of true per-tenant backup size, because `velero_backup_tarball_size_bytes` covers just
  the object manifest (measured ~52x understatement on the lab) and is labelled only by `schedule`.
- **`servicemonitors.yaml`** also scrapes the **Cilium agent + Hubble** metrics (enabled via the cilium
  values); **`ceph-scrape.yaml`** is a per-site template for an external Ceph mgr (fill the endpoint).

The `talu:tenant_*` series (per namespace): `vmi_count`, `vcpu_cores:allocated`,
`memory_bytes:allocated`/`:resident`, `network_{receive,transmit}_bytes:total` (+ transmit rate),
`storage_bytes:requested`, `storage_{read,write}_bytes:total`, and `quota_used`/`quota_hard`
(the `ResourceQuota` envelope — now a tenant-chart default).

## Alerting

The 34 kube-prometheus-stack default rules **plus** Talu's `backup`/`node`/`resource` rules now have a
destination: **Alertmanager** (`values.yaml`). By default the receiver is **null** — alerts fire, group,
and are visible in the **Alertmanager UI** (`alertmanager.<domain>`, admin-only via Pomerium) and the
Perses **Alerts** dashboard, but notify **nowhere**. This is deliberate: Talu is orchestrator-agnostic,
so it ships no hardcoded destination.

To actually notify, pick one:
- **Webhook** (orchestrator-agnostic default): set `alerting_webhook_url` (ansible `group_vars`) to an
  incoming-webhook URL; the monitoring role injects it on both the `default` and `critical` receivers.
- **Slack / email / PagerDuty**: add `slack_configs` / `email_configs` / `pagerduty_configs` to the
  receivers under `alertmanager.config` in `values.yaml` (a values swap — no code change).

Routing: a `severity="critical"` child route repeats hourly (vs 4h default); inhibit rules suppress
per-node noise while a node is `NotReady`, and warnings when the matching critical is already firing.

## Deploying

Production/GitOps path is the **HelmRelease** (Flux helm-controller). The rocky-sandbox lab bootstraps
it via Helm directly (`helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack
-n monitoring -f values.yaml`), because helm-controller is flaky on the nested node. Validated on the
lab: KubeVirt/KSM/node-exporter scraped, and every `talu:tenant_*` rule populates for a live tenant.

This is a reusable base — part of `components/` (the product). Adopters do **not** edit it;
site-specific values (retention, storage, resources) live in `environments/<site>/`. See
`docs/customize/` for the customization boundary.

**Per-tenant** dashboards (a namespace-scoped `prom-label-proxy` + Perses, Pomerium-fronted) are rendered
by the **tenant chart** (`components/tenancy/tenant-chart`, `dashboards.enabled`) — this operator stack and
the tenant stacks share the same Prometheus. See
[`../../../monitoring-accounting-plan.md`](../../../monitoring-accounting-plan.md).
