# ci — forge-agnostic pipeline templates

Filled in when a forge is chosen. Two pipelines: (1) image builds (`virt-sparsify`,
`cosign` sign, push to zot) on schedule + base-image change; (2) plugin/chart tests
from committed state only. CI runs the `rocky-sandbox` overlay as the e2e gate.
Fork-and-track today; a component OCI-artifact release pipeline can be added here
later without restructuring.
