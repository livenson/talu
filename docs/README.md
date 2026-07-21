# Talu documentation

| Section | Purpose |
|---|---|
| [architecture/](architecture/) | what Talu is and why — [component diagram](architecture/), [runtime flows](architecture/flows.md), [networking](architecture/networking.md) |
| [install/](install/) | deploying Talu on your own (KVM) hardware |
| [customize/](customize/) | the customization boundary + tracking upstream |
| [integrations/](integrations/) | driving Talu from an external orchestrator (e.g. Waldur, a portal, or CI) |
| [development/](development/) | the Rocky 10 quick-mode validation path + dev loop |
| [operations/](operations/) | runbooks — incl. [backup & restore flows](operations/backup-restore.md) |

**Platform tiers** (deployed by `ansible/` roles; per-component detail in each `components/platform/*/README.md`):
observability (Prometheus + Perses dashboards — fleet, network/security, per-VM, **Access & Identity**, backup/DR),
**audit** (Loki + Alloy → the **Access Audit** dashboard *in Perses*, "who accessed what, when"), and
**backup/DR** (Velero + node-agent → Garage — see [operations/backup-restore.md](operations/backup-restore.md)).

**Start here:** [architecture/](architecture/) for the component diagram, then
[architecture/flows.md](architecture/flows.md) for the provisioning, SSH, and integration
sequence diagrams.
