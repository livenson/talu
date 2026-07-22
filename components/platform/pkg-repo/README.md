# pkg-repo — in-cluster OS-package repository (optional)

A tiny **nginx serving a PVC over HTTP** that hosts the `talu-ca-trust` package (and any future
cluster-specific packages) for **mutable guests** to install + auto-update — the OS-package analog of
zot's image registry. bootc guests don't need it (they bake the package into the image).

```sh
kubectl apply -k components/platform/pkg-repo         # into golden-images ns (from the image catalog)
```

- Serves `http://pkg-repo.golden-images.svc/deb/` (flat apt repo; browsable via nginx autoindex).
- Populated by [`images/ca-trust/publish.sh`](../../../images/ca-trust/publish.sh) (build → index → sync
  the PVC). On the lab that runs host-side + `kubectl cp`; production runs it as an in-cluster Job.
- Runs unprivileged (uid 101, `fsGroup` so the publisher can write) — PSA-`restricted` clean.

Guests point at it via the tenant chart `caTrust.package=true` + `caTrust.aptRepoLine`. Full picture,
including the bootc path and the rotation tie-in: [`docs/operations/packages.md`](../../../docs/operations/packages.md).
