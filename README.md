# apt-charliek

Public Debian/Ubuntu apt repository for Charlie Knudsen's open-source projects (`prox`, `shed-server`, `envsecrets`, ...). Companion to [`charliek/homebrew-tap`](https://github.com/charliek/homebrew-tap) for macOS.

## Install

```bash
curl -fsSL https://apt.stridelabs.ai/pubkey.gpg | \
  sudo tee /etc/apt/keyrings/apt-charliek.gpg > /dev/null
echo 'deb [signed-by=/etc/apt/keyrings/apt-charliek.gpg] https://apt.stridelabs.ai noble main' | \
  sudo tee /etc/apt/sources.list.d/apt-charliek.list
sudo apt update
sudo apt install prox
```

Tested on Pop!_OS 24.04 and Ubuntu 24.04+.

## What's in it

| Package | Source | Description |
|---|---|---|
| `prox` | [charliek/prox](https://github.com/charliek/prox) | Modern process manager for development with API-first design |
| `shed-server` | [charliek/shed](https://github.com/charliek/shed) | CLI and server for managing persistent VM-based dev environments |
| `envsecrets` | [charliek/envsecrets](https://github.com/charliek/envsecrets) | CLI for managing encrypted environment files using GCS and age |

The full list is in [`packages.yaml`](packages.yaml).

## How it works

Source repos cut releases via GoReleaser, attach `.deb` artifacts (built with `nfpm`) to their GitHub Releases, and fire a `repository_dispatch` event at this repo. This repo's publish workflow re-scans every tracked package's latest release, regenerates apt metadata with `apt-ftparchive`, signs it with an ed25519 key, and uploads to a public GCS bucket fronted by Cloudflare.

Total time from `git push --tags` in a source repo to `apt update` showing the new version: ~3–5 minutes.

For the architecture diagram, security model, and idempotency notes, see [How It Works](https://charliek.github.io/apt-charliek/getting-started/how-it-works/).

## Adding a package

1. Add an `nfpms:` block to the source repo's `.goreleaser.yaml`.
2. Add a final "Trigger apt-charliek publish" step to the source repo's release workflow (uses an `APT_DISPATCH_TOKEN` secret).
3. Append an entry to `packages.yaml` here.

Full contract with copy-paste snippets: [Adding a Package](https://charliek.github.io/apt-charliek/guides/adding-a-package/).

## Local development

```bash
git clone git@github.com:charliek/apt-charliek.git
cd apt-charliek
uv sync --group docs
make help
make check        # lint + docs --strict + fixture publish + smoke test
```

`make check` is the PR-equivalent gauntlet — runs the entire pipeline against a committed fixture deb and an ephemeral GPG key. No real GCS, no real signing key.

For the local dev runbook (envsecrets, fixture rebuild, etc.) see [Setup](https://charliek.github.io/apt-charliek/development/setup/).

## Documentation

Full documentation: <https://charliek.github.io/apt-charliek/>

- [Quick Start](https://charliek.github.io/apt-charliek/getting-started/quick-start/) — install + verify
- [Adding a Package](https://charliek.github.io/apt-charliek/guides/adding-a-package/)
- [GCP Setup](https://charliek.github.io/apt-charliek/guides/gcp-setup/)
- [Cloudflare Setup](https://charliek.github.io/apt-charliek/guides/cloudflare-setup/)
- [Secrets](https://charliek.github.io/apt-charliek/development/secrets/) — GPG key custody and rotation
- [Release Flow](https://charliek.github.io/apt-charliek/development/release-flow/) — what happens on `git push --tags`

## License

The shell scripts, workflows, and configuration in this repo are MIT-licensed. The packages distributed via the apt repo carry their own licenses — see each package's source repo.
