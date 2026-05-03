# `Release` File Fields

`apt-ftparchive release` generates `dists/noble/Release` from `apt-ftparchive.conf` plus the Packages files it finds in the tree. The relevant fields:

## Emitted

| Field | Source | Notes |
|---|---|---|
| `Origin` | conf | `charliek` |
| `Label` | conf | `charliek apt repo` |
| `Suite` | conf | `noble` |
| `Codename` | conf | `noble` |
| `Components` | conf | `main` |
| `Architectures` | conf | `amd64 arm64` |
| `Description` | conf | "Debian/Ubuntu apt repository for charliek open-source projects" |
| `Date` | runtime | RFC 2822 UTC, the moment publish ran |
| `MD5Sum`, `SHA1`, `SHA256`, `SHA512` | runtime | Per-`Packages*` checksum block |

## Deliberately omitted

### `Valid-Until`

If set, apt-secure rejects the repo after that timestamp. Setting it forces a "republish-or-go-stale" cadence (typically weekly). For a low-volume indie repo, that's busy-work and a foot-gun: a long break in releases or a CI outage breaks `apt update` for every user until you push a fresh signed `InRelease`.

We omit it. Mirrors that want a freshness signal can rely on `Date:` or pin to a specific point. If we ever introduce mirroring, revisit.

### `NotAutomatic` / `ButAutomaticUpgrades`

These control whether apt picks new versions automatically. We want auto-upgrade behavior — installing `prox` and then running `apt upgrade` should pull a newer `prox` without extra ceremony. Default (both unset) gives that. Don't add either field.

### `Acquire-By-Hash`

Modern apt supports `Acquire-By-Hash: yes` for atomic mirror-safe metadata reads. Pairs with `by-hash/<algo>/<digest>` directories alongside each `Packages` file.

We don't generate by-hash directories (single-origin, atomic upload order, Cloudflare bypass on `dists/**` — the race window is negligible). So we also don't claim `Acquire-By-Hash`. If we ever add mirrors, enable both.

## Signing

`apt-ftparchive release` produces an unsigned file. The publish script wraps it twice:

- `gpg --clearsign Release > InRelease` — single file containing both the metadata and the signature. Modern apt fetches this preferentially.
- `gpg --detach-sign --armor Release > Release.gpg` — separate signature; older apt clients use this with `Release`.

Both are uploaded so any apt version Just Works.

## Inspecting a published Release file

```bash
curl -fsSL https://apt.stridelabs.ai/dists/noble/Release | head -20
```

To verify the signature locally:

```bash
curl -fsSL https://apt.stridelabs.ai/pubkey.gpg | gpg --import
curl -fsSL https://apt.stridelabs.ai/dists/noble/InRelease | gpg --verify
```

Successful output ends with `gpg: Good signature from "Charlie Knudsen apt repo <apt@stridelabs.ai>"`.
