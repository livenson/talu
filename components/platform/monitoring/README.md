# monitoring

**Responsibility:** the metrics half of the integration contract — a Prometheus that scrapes the
substrate and emits the **per-namespace usage recording rules** an external orchestrator reads for
accounting (the § READ verb). Billing/€-conversion is *not* here — it lives in the orchestrator.

## What's in here

- **`helmrepository.yaml` / `helmrelease.yaml` / `values.yaml`** — `kube-prometheus-stack` (pinned
  `87.17.0`, app `v0.92.1`) **Prometheus-only**: Prometheus-operator + Prometheus + kube-state-metrics
  + node-exporter. Grafana is **off** (Perses is the dashboard layer, exposed via Pomerium — Phase 2);
  Alertmanager is **off** (alerting deferred). Prometheus selects all ServiceMonitors/Rules
  cluster-wide, and the Talos/Cilium-inapplicable scrapers (etcd/scheduler/controller-manager/kube-proxy)
  are disabled. Upstream: <https://github.com/prometheus-community/helm-charts>.
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
  - `dashboard-vmdetail.yaml` — **per-VM drill-down** with `$namespace`+`$vm` pickers (CPU / memory /
    disk throughput & IOPS / network from `kubevirt_vmi_*`).
- **`servicemonitors.yaml`** also scrapes the **Cilium agent + Hubble** metrics (enabled via the cilium
  values); **`ceph-scrape.yaml`** is a per-site template for an external Ceph mgr (fill the endpoint).

The `talu:tenant_*` series (per namespace): `vmi_count`, `vcpu_cores:allocated`,
`memory_bytes:allocated`/`:resident`, `network_{receive,transmit}_bytes:total` (+ transmit rate),
`storage_bytes:requested`, `storage_{read,write}_bytes:total`, and `quota_used`/`quota_hard`
(the `ResourceQuota` envelope — now a tenant-chart default).

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
