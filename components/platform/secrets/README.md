# secrets

**Responsibility:** the secrets-at-rest mechanism — **SOPS + age** — and its Flux wiring.

Talu's rule (stated in `docs/customize/`, `docs/install/`, and enforced by `.gitignore`): **the repo
ships only `*.example` stubs; real secret values are encrypted with SOPS/age.** This component makes
that operational. The full model, key layout, and the phased migration off the currently-committed
plaintext are in [`docs/operations/secrets.md`](../../../docs/operations/secrets.md).

## What's in here

- **`pomerium-idp.secret.example.yaml`** — the *shape* of a SOPS-encrypted Secret (plaintext stub).
  Copy into an environment overlay as `secrets.yaml`, fill real values, `sops -e -i` it.
- **`kustomization.yaml`** — deliberately **empty of resources**. See the trap below.

## The one trap: kustomize does not decrypt

`kustomize build | kubectl apply` — the `dev/lab/sync.sh` fast path **and** `make kbuild` — has no
SOPS awareness. If an encrypted Secret sits in the kustomize resource graph, it renders as **ciphertext**
and applies broken (or, worse, a *plaintext* secret leaks into the build output). So:

- **Never** list an encrypted Secret in a `kustomization.yaml` `resources:`.
- Apply encrypted Secrets only via a SOPS-aware path:
  - **Flux (production):** a `Kustomization` with
    ```yaml
    spec:
      decryption:
        provider: sops
        secretRef: { name: sops-age }   # holds the age PRIVATE key; kustomize-controller decrypts
    ```
  - **By hand (lab):** `sops -d environments/<site>/secrets.yaml | kubectl apply -f -`.

## The one irreducible bootstrap secret

The age **private** key. Flux reads it from a `sops-age` Secret in `flux-system`; create it out-of-band:

```sh
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```

Humans and ansible read the same key via `SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/keys.txt`.
Everything else can live encrypted in Git.

This is a reusable base — part of `components/` (the product). Adopters do **not** edit it; per-site
encrypted `secrets.yaml` files live in `environments/<site>/`.
