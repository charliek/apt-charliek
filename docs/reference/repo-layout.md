# Bucket Layout

What apt-charliek writes into `gs://apt.stridelabs.ai/`.

## Tree

```text
gs://apt.stridelabs.ai/
├── pubkey.asc                            (armored, for humans)
├── pubkey.gpg                            (binary, for signed-by= in sources.list)
├── healthcheck                           (written by infra/setup.sh, ignorable)
├── dists/noble/
│   ├── InRelease                         (clearsigned Release)
│   ├── Release                           (unsigned, used for hash auditing)
│   ├── Release.gpg                       (detached armored signature)
│   └── main/
│       ├── binary-amd64/
│       │   ├── Packages
│       │   └── Packages.gz
│       └── binary-arm64/
│           ├── Packages
│           └── Packages.gz
└── pool/main/
    ├── e/envsecrets/envsecrets_*.deb
    ├── p/prox/prox_*.deb
    └── s/shed-server/shed-server_*.deb
```

## Why `pool/main/<letter>/<name>/`

Debian convention. The first letter of the package name is the second-level subdirectory. It exists to keep any single directory from accumulating thousands of entries; for a small repo the structure is overkill but apt's tooling expects it and there's no upside to deviating.

## Suite vs component vs architecture

- **Suite** (`noble`): the user-facing release codename in `sources.list`. apt-charliek ships a single suite for now.
- **Component** (`main`): apt's tier — `main` / `contrib` / `non-free` etc. Only `main` is used.
- **Architecture** (`amd64`, `arm64`): one `Packages` file per arch under `binary-<arch>/`. An arch with no debs still gets an empty `Packages` file.

## Atomic upload order

The publish workflow uploads in a specific order so that, at any moment between steps, users see a consistent metadata view:

1. `pool/` — additive; idempotent. New debs are visible but no metadata references them yet.
2. `dists/noble/main/binary-<arch>/Packages` and `Packages.gz` — written but not yet referenced by `Release`.
3. `dists/noble/Release` — references the new `Packages` files.
4. `dists/noble/Release.gpg` — detached signature on the new `Release`.
5. `dists/noble/InRelease` — clearsigned `Release`. **apt fetches this first**, so flipping it last is the atomic-commit point.

Until step 5, apt sees the previous `InRelease` and the previous (consistent) view. After step 5, apt sees the new view. There is no "in between."

## Caching

| Path | Cloudflare | Origin (`Cache-Control`) |
|---|---|---|
| `dists/**` | Bypass cache | `no-cache` (set explicitly by `publish.sh`) |
| `pool/**` | Edge TTL 1 month | (default) |
| `pubkey.{gpg,asc}` | (default — short TTL) | (default) |

The two cache settings layer: even if Cloudflare's cache rule is misconfigured, GCS's `Cache-Control: no-cache` on `dists/**` objects keeps clients honest.

## Object Versioning

Enabled on the bucket. Past versions of overwritten objects (mostly the `dists/**` metadata files) are retained. Cheap rollback insurance against a bad publish, though full rebuild from GitHub releases is the canonical recovery.
