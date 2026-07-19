# Runtime flows

Sequence diagrams for the flows that matter. All are **declarative**: a client writes Kubernetes
objects and watches status; Talu never calls out to an external system. See
[`README.md`](README.md) for the component architecture.

## Tenant / VM provisioning

A tenant is one `HelmRelease` applied **directly to the Kubernetes API** (by an orchestrator, a CI
job, or a human — or committed to Git and reconciled). Flux's helm-controller renders the
`talu-tenant` chart into the per-tenant bundle. `HelmRelease.status` is the single object to watch;
deleting it garbage-collects the whole tenant.

```mermaid
sequenceDiagram
    actor O as Orchestrator / Git / human
    participant API as Kubernetes API
    participant F as Flux helm-controller
    participant SRC as Chart source (OCIRepository)
    participant KV as KubeVirt

    O->>API: apply HelmRelease (chart=talu-tenant, values, talu.io/project-uuid)
    F->>SRC: fetch talu-tenant chart
    F->>F: render bundle — namespace, ResourceQuota, RBAC,<br/>cloud-init Secret, VirtualMachine, ssh Service, CiliumNetworkPolicies
    F->>API: apply tenant objects (owned by the release)
    API->>KV: VirtualMachine created
    KV->>KV: start VMI — cloud-init from Secret<br/>(TrustedUserCAKeys + guest secrets)
    O->>API: watch HelmRelease.status + VMI conditions
    API-->>O: Ready=True / VMI Running
    Note over O,API: delete the HelmRelease → Flux GC removes the entire tenant bundle
```

## SSH access (Pomerium Native SSH)

There is no public `:22` and no static VM password. Pomerium is the SSH proxy **and** the SSH User
CA; the VM trusts that CA (injected via cloud-init). The user runs a stock `ssh` client; Pomerium
authenticates them via OIDC in the browser, issues a short-lived certificate, and connects. Cilium
pins the VM's `:22` so only Pomerium can reach it.

```mermaid
sequenceDiagram
    actor U as User (tenant member)
    participant SSH as ssh client
    participant P as Pomerium<br/>(SSH proxy + User CA)
    participant IDP as OIDC IdP
    participant VM as VM sshd<br/>(trusts Pomerium User CA)

    U->>SSH: ssh <user>@<vm>@ssh.<host> -p <port>
    SSH->>P: connect, offer public key
    P-->>SSH: keyboard-interactive → "open this URL"
    U->>IDP: browser login (OIDC)
    IDP-->>P: authenticated (email / groups)
    P->>P: route policy check (allow-list) +<br/>sign a short-lived SSH cert for the key
    P->>VM: connect with the signed cert<br/>(Cilium NetworkPolicy: only Pomerium may reach :22)
    VM-->>U: shell as the cert principal — no password anywhere
```

## The integration contract

An external orchestrator participates through exactly **four verbs**. Talu exposes no proprietary
API and never initiates calls to the orchestrator — the object labels and `.status` are the whole
interface. Examples of orchestrators that consume this contract: a billing/portal platform such as
**Waldur**, an internal self-service portal, or a CI/CD pipeline.

```mermaid
sequenceDiagram
    actor O as Orchestrator
    participant API as Kubernetes API
    participant PR as Prometheus HTTP API
    participant IDP as OIDC IdP

    rect rgb(238,245,255)
    Note over O,API: 1 · WRITE — labelled objects
    O->>API: apply HelmRelease / VMs (talu.io/project-uuid on every object)
    end
    rect rgb(238,255,238)
    Note over O,API: 2 · WATCH — the only progress signal
    O->>API: watch .status (HelmRelease Ready, VMI conditions, route readiness)
    API-->>O: readiness / health
    end
    rect rgb(255,247,230)
    Note over O,PR: 3 · READ — usage for billing
    O->>PR: per-namespace PromQL (cpu / memory / disk / network)
    PR-->>O: metered usage
    end
    rect rgb(245,238,255)
    Note over O,IDP: 4 · DELEGATE — identity
    O->>IDP: create group / user for the project
    Note right of IDP: authorization = OIDC group membership
    end
```

**What a consumer must not assume:** no imperative side channels (declarative objects only); labels
are truth, names are handles (`talu.io/project-uuid` is the join key); and Talu may run with **no
orchestrator at all** — never design objects that require one to exist.
