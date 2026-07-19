# Architecture

Talu is an open-source, multitenant **VM platform** built on a Kubernetes + KubeVirt substrate.
Its entire management surface is the **Kubernetes declarative API plus the Prometheus HTTP API** —
there is no proprietary control plane. That makes it **API-first and orchestrator-agnostic**: an
external billing/portal/automation system drives Talu through a stable contract, and Talu also runs
fully standalone (Git-first, no orchestrator at all).

- **Runtime flows with sequence diagrams:** [`flows.md`](flows.md).
- **Network architecture** (Cilium, VM security, L2/L3, IPv4/IPv6, IPAM, LB): [`networking.md`](networking.md).
- **How Talu compares** (Cozystack, Harvester, OpenShift Virt, OpenStack, Proxmox…): [`comparison.md`](comparison.md).
- Driving Talu from an external system: [`../integrations/`](../integrations/).
- Operating guide & validated gotchas (the hard-won lab lessons): [`../../CLAUDE.md`](../../CLAUDE.md)
  and [`../development/lab-notes.md`](../development/lab-notes.md).

## The layers

```mermaid
graph TD
    subgraph EXT["External (optional) — orchestrator boundary"]
        ORCH["Orchestrator / portal / automation<br/>(any K8s-API client)"]
    end

    subgraph ACCESS["Access plane — the only ingress"]
        POM["Pomerium<br/>IAP + Native SSH proxy &amp; SSH User CA"]
        IDP["OIDC IdP<br/>(generic: Dex / Keycloak / ZITADEL)"]
        CM["cert-manager<br/>(internal CA + TLS)"]
    end

    subgraph TENANCY["Tenancy — the tenant API"]
        FLUX["Flux helm-controller"]
        CHART["talu-tenant chart<br/>(the tenant API schema)"]
        subgraph TNS["Per-tenant namespace (talu.io/project-uuid)"]
            VM["VirtualMachine(s)"]
            SVC["ssh Service + CiliumNetworkPolicy<br/>(pinning + security groups)"]
            QUOTA["ResourceQuota + scoped RBAC"]
            SEC["cloud-init Secret<br/>(CA trust + guest secrets)"]
        end
    end

    subgraph VIRT["Virtualization"]
        KV["KubeVirt + CDI"]
    end

    subgraph SUBSTRATE["Substrate"]
        TALOS["Talos Linux nodes"]
        CILIUM["Cilium CNI<br/>(NetworkPolicy, LB-IPAM, kube-proxy-less)"]
        CEPH["CephFS (ceph-csi)<br/>RWX storage"]
    end

    subgraph OBS["Observability"]
        PROM["Prometheus<br/>(usage / billing metrics)"]
    end

    ORCH -->|"1. write labelled objects<br/>(HelmRelease / VMs)"| FLUX
    ORCH -->|"2. watch .status"| TNS
    ORCH -->|"3. read usage (HTTP API)"| PROM
    ORCH -->|"4. delegate identity (OIDC)"| IDP

    FLUX --> CHART --> TNS
    POM --> IDP
    POM -->|"cert-auth SSH"| VM
    VM --> KV --> TALOS
    SVC --> CILIUM
    SEC --> VM
    KV --> CEPH
    PROM -.scrapes.-> KV & CILIUM & TNS

    classDef opt fill:#eeeeee,stroke:#999999,color:#111827,stroke-dasharray:4 3;
    class ORCH opt;
```

## Reading the diagram

- **The orchestrator boundary is dashed and optional.** Everything below it runs without it. An
  external system participates only through four verbs (write / watch / read / delegate — see
  [`flows.md`](flows.md#the-integration-contract)); Talu never calls out to it.
- **Access plane = the only ingress.** All human and machine access enters through **Pomerium**,
  which is both the HTTP identity-aware proxy *and* the native SSH proxy + SSH User CA. Authentication
  is delegated to a **generic OIDC IdP** (Dex on the lab; Keycloak/ZITADEL in production — a values
  swap). There is no public `:22` and no static VM password.
- **Tenancy = the tenant API.** A tenant is a set of values rendered by the **`talu-tenant` chart**.
  The chart's `values.schema.json` *is* the API. Applying a `HelmRelease` (directly to the K8s API, or
  from Git) makes Flux's helm-controller render the per-tenant bundle; deleting it garbage-collects the
  whole tenant. Every object carries **`talu.io/project-uuid`** — the join key any orchestrator uses.
- **Substrate is standard and swappable.** Talos immutable nodes, Cilium (network policy + LB-IPAM,
  no kube-proxy), CephFS for RWX storage. The no-KVM validation lab runs this same stack nested; real
  deployments run it on KVM nodes — a values change, not a rebuild.

## Design rules (the invariants)

1. **Bake capabilities, inject identity.** Golden images carry the software; per-tenant identity/secrets
   arrive at boot via cloud-init from a Secret. Images are generic and reusable.
2. **`components/` is the product; `environments/<site>/` is your config.** Adopters add an overlay,
   never edit bases, so upstream releases merge cleanly. See [`../customize/`](../customize/).
3. **Labels are truth, names are handles.** Nothing joins on names; `talu.io/project-uuid` is the key.
4. **Declarative only.** No imperative side channels — the orchestrator writes objects and watches status.
5. **Standalone-first.** No object requires an orchestrator to exist.

## The building blocks (upstream docs)

Talu is an assembly of standard components — the authoritative reference for each is upstream:

| Layer | Component | Docs |
|---|---|---|
| OS | Talos Linux | <https://www.talos.dev/latest/> |
| CNI / dataplane | Cilium | <https://docs.cilium.io/en/stable/> |
| Virtualization | KubeVirt · CDI | <https://kubevirt.io/user-guide/> · <https://github.com/kubevirt/containerized-data-importer> |
| Storage | ceph-csi (CephFS) · Rook (prod) | <https://github.com/ceph/ceph-csi> · <https://rook.io/docs/rook/latest/> |
| Tenancy | Flux (helm-controller) | <https://fluxcd.io/flux/components/helm/helmreleases/> |
| Access | Pomerium (Native SSH) · Dex · cert-manager | <https://www.pomerium.com/docs/capabilities/native-ssh-access> · <https://dexidp.io/docs/> · <https://cert-manager.io/docs/> |
| Platform | Kubernetes (Pod Security Admission) | <https://kubernetes.io/docs/concepts/security/pod-security-admission/> |
