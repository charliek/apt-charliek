# Secrets

apt-charliek has one durable secret: the ed25519 GPG signing-only private key. It lives in three places:

| Where | Format | Purpose |
|---|---|---|
| `.secrets/apt-signing-key.asc` | armored | Local on-disk copy, synced across your laptops via `envsecrets` |
| `.secrets/apt-signing-key.fpr` | plain text | Fingerprint convenience file |
| `APT_SIGNING_KEY` GitHub Actions secret | armored | Consumed by `publish.yml` |
| `APT_SIGNING_KEY_FPR` GitHub Actions secret | plain text | Tells `publish.sh` which key in the imported keyring to use |

There is **no copy** in Google Secret Manager or any other vault. The two places (your laptops + GitHub Actions) are the security boundary. If both are compromised, an attacker has signing capability.

The pubkey at `gs://apt.stridelabs.ai/pubkey.gpg` is regenerated on every publish; it's derived from the secret, not separately stored.

## One-time generation

```bash
KEY_UID='Charlie Knudsen apt repo <apt@stridelabs.ai>'
gpg --batch --pinentry-mode loopback --passphrase '' \
    --quick-generate-key "$KEY_UID" ed25519 sign 0
# 'sign' = signing-only (no encryption capability)
# '0'    = no expiration; --passphrase '' = no passphrase (CI consumes unattended)

# Match the key by user-id, not by listing all keys — if you have other keys
# in your keyring, a blind `awk … exit` would grab the wrong one.
FPR=$(gpg --list-secret-keys --with-colons "$KEY_UID" \
        | awk -F: '/^fpr:/ { print $10; exit }')
[ -n "$FPR" ] || { echo "could not resolve fingerprint for $KEY_UID" >&2; exit 1; }

mkdir -p .secrets
gpg --armor --export-secret-keys "$FPR" > .secrets/apt-signing-key.asc
echo -n "$FPR" > .secrets/apt-signing-key.fpr

envsecrets push -m "Initial apt signing key"

# Upload to GitHub Actions
gh secret set APT_SIGNING_KEY     --repo charliek/apt-charliek --body-file .secrets/apt-signing-key.asc
gh secret set APT_SIGNING_KEY_FPR --repo charliek/apt-charliek --body-file .secrets/apt-signing-key.fpr
```

Why **ed25519, signing-only, no expiration**:

- ed25519 keys are short, fast, and supported by every apt version we care about.
- Signing-only avoids accidentally using the same key for anything else.
- No expiration removes the "key expired and `apt update` is broken for every user" foot-gun. Indie scope; documented tradeoff.

## On a new machine

```bash
git clone git@github.com:charliek/apt-charliek.git
cd apt-charliek
envsecrets pull
# .secrets/apt-signing-key.{asc,fpr} restored
```

To use the key locally (e.g. to sign a republish out-of-band):

```bash
gpg --import .secrets/apt-signing-key.asc
```

## Rotation

If you suspect the key is compromised, or just want to rotate on a schedule:

1. Generate a new ed25519 key (same command as above) into a fresh `$GNUPGHOME`.
2. Overwrite `.secrets/apt-signing-key.{asc,fpr}` with the new key's exports.
3. `envsecrets push -m "Rotate apt signing key"`.
4. Update `APT_SIGNING_KEY` and `APT_SIGNING_KEY_FPR` GitHub secrets.
5. Trigger `publish.yml` via `workflow_dispatch` to publish the new `pubkey.gpg`.
6. Notify users to re-pull the pubkey:

   ```bash
   curl -fsSL https://apt.stridelabs.ai/pubkey.gpg | \
     sudo tee /etc/apt/keyrings/apt-charliek.gpg > /dev/null
   sudo apt update
   ```

The old pubkey can stay published alongside the new one if you want a transition window, but for an indie repo the cleaner path is "swap, send the snippet, done."

## Secrets the CI runner uses

| Secret | Set by |
|---|---|
| `GCP_WIF_PROVIDER` | `infra/setup.sh` prints the value; `gh secret set` it |
| `GCP_SA_EMAIL` | `infra/setup.sh` prints the value; `gh secret set` it |
| `APT_SIGNING_KEY` | `gh secret set ... --body-file .secrets/apt-signing-key.asc` |
| `APT_SIGNING_KEY_FPR` | `gh secret set ... --body-file .secrets/apt-signing-key.fpr` |
| `GITHUB_TOKEN` | Auto-provided by GitHub Actions for `gh release download` |

## Source-repo secret

Source repos that fire `repository_dispatch` need an `APT_DISPATCH_TOKEN` secret. That's a separate fine-grained PAT scoped to `charliek/apt-charliek` only with `Contents: write`. Created and managed outside this repo. See [Adding a Package](../guides/adding-a-package.md).
