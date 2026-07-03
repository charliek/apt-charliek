# charliek apt repo

Public Debian/Ubuntu apt repository for [charliek](https://github.com/charliek)'s open-source projects. Companion to [`charliek/homebrew-tap`](https://github.com/charliek/homebrew-tap) for macOS users.

## Install

Add the repo once:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.stridelabs.ai/pubkey.gpg | \
  sudo tee /etc/apt/keyrings/apt-charliek.gpg > /dev/null
echo 'deb [signed-by=/etc/apt/keyrings/apt-charliek.gpg] https://apt.stridelabs.ai noble main' | \
  sudo tee /etc/apt/sources.list.d/apt-charliek.list
sudo apt update
```

Then install one or more packages:

```bash
sudo apt install prox
```

## Packages

| Package | Status | Description |
|---|---|---|
| [`prox`](https://github.com/charliek/prox) | ✓ published | Modern process manager for development with API-first design |
| [`shed-server`](https://github.com/charliek/shed) | ✓ published | Server component of [shed](https://github.com/charliek/shed) (the CLI ships via Homebrew on macOS) |
| [`envsecrets`](https://github.com/charliek/envsecrets) | ✓ published | CLI for managing encrypted environment files via GCS and age |
| [`roost`](https://github.com/charliek/roost) | ✓ published | Multi-project terminal multiplexer for AI coding agents (GTK desktop app + `roostctl` CLI; macOS ships as a DMG) |
| [`codelens`](https://github.com/charliek/codelens) | ✓ published | Analyze JVM codebases (Java & Kotlin) — classes, methods, handlers, and more (ships JDK 21+ server JAR alongside the Go CLI) |
| [`shed-machine-rc`](https://github.com/charliek/shed-extensions) | ✓ published | RC session helper for native machines — create/watch `claude remote-control` sessions on hosts that aren't sheds (host-side sibling of `shed-ext-rc`) |
| [`shed-desktop`](https://github.com/charliek/shed-desktop) | ◷ pending first release | GTK4/libadwaita Linux desktop client for [shed](https://github.com/charliek/shed) (ships the `shedctl` CLI too; macOS ships as a DMG) |

Tracked packages live in [`packages.yaml`](packages.yaml). Status reflects whether the source project's release pipeline ships a `.deb` yet.

`roost` is a GUI application — after `sudo apt install roost`, launch it from your desktop's app menu (or run `roost`). It also installs the `roostctl` CLI for shell + AI-agent hook integration.

## Supported platforms

- **Architectures**: `amd64`, `arm64`
- **Distros**: Pop!_OS 24.04, Ubuntu 24.04+ (Debian 12 likely works for CLI-only packages but isn't tested)
- **Out of scope**: Ubuntu 22.04 LTS and earlier, Fedora/openSUSE/Arch (no `rpm` channel today)

## Direct `.deb` download (no apt repo)

For one-off installs without configuring the apt repo, every release attaches `.deb` artifacts to the source project's GitHub Release. Pattern:

```bash
ARCH=$(dpkg --print-architecture)
VERSION=<version from the source repo's releases page>
curl -fLO "https://github.com/charliek/<project>/releases/download/v${VERSION}/<project>_${VERSION}_${ARCH}.deb"
sudo apt install -y "./<project>_${VERSION}_${ARCH}.deb"
```

`apt install ./...deb` resolves dependencies automatically; plain `sudo dpkg -i` would skip that step and leave the system in an inconsistent state if the package gains dependencies later.

See each project's README for the exact filename and a worked example (e.g. [prox's installation section](https://github.com/charliek/prox#installation)).

## How it works (briefly)

Source repos cut releases via GoReleaser, attach `.deb` artifacts to their GitHub Releases, and fire `repository_dispatch` at this repo. The publish workflow regenerates apt metadata, signs it with an ed25519 key, and uploads to a GCS bucket fronted by Cloudflare. Total tag-to-`apt update` time: ~3–5 minutes.

Full architecture, security model, and release-flow walkthrough: <https://charliek.github.io/apt-charliek/>.

## Adding a new package

Three-step contract for project owners — see the [Adding a Package guide](https://charliek.github.io/apt-charliek/guides/adding-a-package/) for full snippets:

1. Add an `nfpms:` block to your `.goreleaser.yaml`.
2. Add a final "Trigger apt-charliek publish" step to your release workflow (uses the `APT_DISPATCH_TOKEN` repo secret).
3. Append an entry to [`packages.yaml`](packages.yaml) here.

## Local development

```bash
git clone git@github.com:charliek/apt-charliek.git
cd apt-charliek
make check        # lint + docs --strict + fixture publish + ubuntu:noble smoke test
```

See the [Setup guide](https://charliek.github.io/apt-charliek/development/setup/) for the full local dev runbook (envsecrets, fixture rebuild, etc.).

## License

Scripts, workflows, and configuration are MIT-licensed. Distributed packages carry their own licenses — see each source repo.
