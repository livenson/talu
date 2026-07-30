# Secrets management (SOPS + age)

How secret values are kept out of Git while still being GitOps-deployable. This is the mechanism the
repo already assumes (`.gitignore`, the `*.example` stubs, `docs/install` & `docs/customize`) — this
runbook is where it's actually specified. Component wiring:
[`components/platform/secrets/`](../../components/platform/secrets/). Rotating existing secrets (SSH
CA, platform secrets, certs): [`rotation.md`](rotation.md).

## Why SOPS + age (and not the alternatives)

| Option | Why not (as the default) |
|---|---|
| **Sealed Secrets** | ciphertext is bound to one cluster's controller key — poor portability across Talu's frequent rebuild loop, and it can't serve the **ansible** path at all. |
| **External Secrets + Vault** | a running Vault violates Talu's standalone-first default. Kept as a documented **opt-in** scale-out (an ESO overlay), not the baseline. |
| **SOPS + age** ✅ | file-level encryption that lives *in Git*, portable, and decryptable by **both** Flux (kustomize-controller) and humans/ansible (`sops -d`) from the *same* files. age keys are tiny and keyless-CA-free. |

## Model

- **What's encrypted:** only secret *values*. `.sops.yaml` `encrypted_regex` limits encryption to
  `data`/`stringData`, so object kind, name, and structure stay readable in diffs.
- **Where encrypted files live:** `environments/<site>/secrets.yaml` (per-site) and any
  `*.secret.yaml` / `ansible/**/*.sops.yaml`. All matched by `.sops.yaml` creation rules.
- **The one irreducible bootstrap secret:** the age **private** key. Everything else is encrypted in
  Git behind it.
  - **Flux** reads it from the `sops-age` Secret in `flux-system`.
  - **Humans / ansible** read it from `SOPS_AGE_KEY_FILE` (default `~/.config/sops/age/keys.txt`).
- **Per-environment keys:** give each site its own age key and list all recipients in `.sops.yaml`, so
  a site is decryptable by its own key and by an ops/break-glass key.

## First-time setup

```sh
# 1. generate your age keypair
age-keygen -o ~/.config/sops/age/keys.txt          # prints "Public key: age1..."

# 2. put that age1... public key into .sops.yaml (replace the placeholder recipient)

# 3. give Flux the PRIVATE key (kustomize-controller decrypts with it)
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt

# 4. encrypt a secret
cp components/platform/secrets/pomerium-idp.secret.example.yaml environments/example/secrets.yaml
$EDITOR environments/example/secrets.yaml           # fill real values
sops -e -i environments/example/secrets.yaml        # encrypts data/stringData in place
```

## Deploying encrypted secrets

**kustomize does not decrypt.** `kustomize build | kubectl apply` (the `dev/lab/sync.sh` fast path and
`make kbuild`) is SOPS-unaware — an encrypted Secret in the resource graph renders as ciphertext.
So encrypted Secrets are applied only via a SOPS-aware path:

- **Flux (production):** the environment's `Kustomization` gets
  ```yaml
  spec:
    decryption:
      provider: sops
      secretRef: { name: sops-age }
  ```
  Keep the encrypted `secrets.yaml` **out** of any `kustomization.yaml` `resources:` list — reference
  it from the Flux Kustomization path instead, so `make kbuild` never touches ciphertext.
- **By hand (lab):** `sops -d environments/<site>/secrets.yaml | kubectl apply -f -`.

### ansible

The physical-lab roles read secrets from ansible vars. Supply them from SOPS instead of committing
plaintext, either via the `community.sops` vars plugin (auto-decrypts `*.sops.yaml` group/host vars) or
an explicit decrypt at invocation:

```sh
sops -d ansible/group_vars/secrets.sops.yaml > /tmp/secrets.yaml
ansible-playbook phys-stack.yml -e @/tmp/secrets.yaml --tags identity && shred -u /tmp/secrets.yaml
```

## Migration — killing the committed plaintext

Two secret-shaped values are committed today (both **demo placeholders**, but the pattern must not
reach production): `pomerium_idp_client_secret` and `dex_user_bcrypt` in `ansible/group_vars/all.yml`
and `phys.yml`. They are flagged in-repo (a `SECURITY:` banner) and allow-listed in the gitleaks gate
as *known demo values*; the gate blocks any **new** secret-shaped string.

Phased, low-risk cutover for a real deployment:

0. **Scaffold** (done): `.sops.yaml`, this doc, `components/platform/secrets/`, the gitleaks CI gate.
1. **Per-site key + `sops-age` Secret**; drop your `age1...` recipient into `.sops.yaml`.
2. **Move the IdP/Dex values** into `ansible/group_vars/secrets.sops.yaml` (encrypted) and delete the
   plaintext defaults; wire `community.sops`. Regenerate both values (`openssl rand -hex 32`;
   `htpasswd -nbBC 10 x <pw> | cut -d: -f2 | sed 's/^$2y/$2a/'`) so the leaked demo values are dead.
3. **Platform secrets minted imperatively** (Pomerium secrets, the SSH CA) → generate once, encrypt,
   commit — this also fixes the rebuild regression where a fresh run mints a *new* SSH CA and
   invalidates guest trust (see [`rotation.md`](rotation.md)).
4. **Tenant guest secrets** → SOPS files (or orchestrator-supplied via the chart's `existingSecret`
   seam) instead of inlined HelmRelease values.
5. **Wire the Flux decryption Kustomization** — completes GitOps.
6. **Optional:** an ESO overlay for teams that already run Vault.

## Guardrail

CI runs **gitleaks** (`.gitleaks.toml`) on every PR/push. The two demo values above are the only
allow-listed exceptions; anything else secret-shaped fails the job. Rotate the demo values (step 2)
before any deployment you consider real.
