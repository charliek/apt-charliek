# apt-charliek

A public Debian/Ubuntu apt repository for Charlie Knudsen's open-source projects. After adding the repo once, friends and Linux users can install and update tools like `prox`, `shed-server`, and `envsecrets` through their normal `apt install` / `apt upgrade` workflow.

!!! note "Status: setup in progress"
    The infrastructure (bucket, signing key, publish workflow) is in place
    but no packages have been onboarded yet. The first to land is `prox`.
    The "What's in it" table below is forward-looking — entries marked
    *(not yet published)* won't be installable until their first release
    fires the publish workflow.

## Install

```bash
curl -fsSL https://apt.stridelabs.ai/pubkey.gpg | \
  sudo tee /etc/apt/keyrings/apt-charliek.gpg > /dev/null
echo 'deb [signed-by=/etc/apt/keyrings/apt-charliek.gpg] https://apt.stridelabs.ai noble main' | \
  sudo tee /etc/apt/sources.list.d/apt-charliek.list
sudo apt update
sudo apt install prox
```

Tested on Pop!_OS 24.04 and Ubuntu 24.04+. Older Ubuntu LTS releases are out of scope.

## What's in it

The repo aggregates `.deb` packages produced by each source project's release pipeline. The `noble` suite ships across Ubuntu 24.04+ derivatives (Pop!_OS 24.04, Ubuntu 24.10, Ubuntu 25.04, etc.) — modern libadwaita and libssl ABIs are stable enough that one set of debs covers all of them.

| Package | Source | Status | Description |
|---|---|---|---|
| `prox` | [charliek/prox](https://github.com/charliek/prox) | tracked *(first publish pending)* | Modern process manager for development with API-first design |
| `shed-server` | [charliek/shed](https://github.com/charliek/shed) | not yet published | CLI and server for managing persistent VM-based dev environments |
| `envsecrets` | [charliek/envsecrets](https://github.com/charliek/envsecrets) | not yet published | CLI for managing encrypted environment files using GCS and age |

Packages are added to the repo by appending an entry to `packages.yaml`. See [Adding a Package](guides/adding-a-package.md).

## Why this repo

- **One distribution channel** for all charliek projects on Linux, paired with [charliek/homebrew-tap](https://github.com/charliek/homebrew-tap) for macOS.
- **Real `apt update` / `apt upgrade`** instead of `wget && dpkg -i` for every release.
- **End-to-end auto-publish** — tagging a release in a source repo triggers GoReleaser → `nfpm` deb → `repository_dispatch` → this repo's publish workflow → updated apt metadata in GCS, all in a few minutes.

For the full architecture and security model, see [How It Works](getting-started/how-it-works.md).

## Pointers

- [Quick Start](getting-started/quick-start.md) — install in 60 seconds.
- [Adding a Package](guides/adding-a-package.md) — onboard a new project.
- [Release Flow](development/release-flow.md) — what happens when you `git push --tags`.
- [GitHub repo](https://github.com/charliek/apt-charliek) — issues, PRs, source.
