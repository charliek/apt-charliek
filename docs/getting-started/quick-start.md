# Quick Start

Add the repo and install one of the packages.

!!! note "Status: setup in progress"
    The infrastructure (bucket, signing key, publish workflow) is in place
    but no packages are tracked yet. The first onboarded package is `prox`,
    landing in a follow-up PR. Until then `apt update` succeeds (signed
    empty repo) but `apt install <pkg>` will not find any of the listed
    packages.

## 1. Add the repository

```bash
sudo install -d -m 0755 /etc/apt/keyrings

curl -fsSL https://apt.stridelabs.ai/pubkey.gpg | \
  sudo tee /etc/apt/keyrings/apt-charliek.gpg > /dev/null

echo 'deb [signed-by=/etc/apt/keyrings/apt-charliek.gpg] https://apt.stridelabs.ai noble main' | \
  sudo tee /etc/apt/sources.list.d/apt-charliek.list

sudo apt update
```

The `install -d` line creates `/etc/apt/keyrings/` with the right mode if it doesn't already exist (minimal Docker images and some fresh installs lack it).

## 2. Install a package

```bash
sudo apt install prox
prox --help
```

## 3. Stay current

```bash
sudo apt upgrade
```

## Supported distros

| Distro | Status |
|---|---|
| Ubuntu 24.04 LTS | Supported |
| Ubuntu 24.10, 25.04, 25.10 | Supported |
| Pop!_OS 24.04 | Supported |
| Debian 12 (bookworm) | Likely works (libadwaita 1.4 — most CLI packages don't care; GUI packages may not) |
| Ubuntu 22.04 LTS | Out of scope |

## Verifying the signature

The `Release` and `InRelease` files at `https://apt.stridelabs.ai/dists/noble/` are signed with an ed25519 GPG key. The pubkey at `https://apt.stridelabs.ai/pubkey.gpg` is what `signed-by=` in your sources list verifies against. Fingerprint and full custody runbook live in [Secrets](../development/secrets.md).

## Removing the repository

```bash
sudo rm /etc/apt/sources.list.d/apt-charliek.list
sudo rm /etc/apt/keyrings/apt-charliek.gpg
sudo apt update
```

Already-installed packages remain; only future updates stop flowing.
