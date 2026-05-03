# How It Works

apt-charliek is a static apt repository: a tree of files in a Google Cloud Storage bucket, fronted by Cloudflare for HTTPS and caching. There is no server-side component.

## Pipeline

```text
Source repos (charliek/prox, charliek/shed, charliek/envsecrets, ...)
    │
    │ git push --tags v1.2.3
    ▼
Source repo's release.yaml
  • GoReleaser builds binaries
  • nfpm produces *.deb, attached to GitHub Release
  • Final step fires repository_dispatch event_type=publish
    │
    ▼
charliek/apt-charliek/.github/workflows/publish.yml
  • WIF auth to GCP
  • Import APT_SIGNING_KEY into ephemeral keyring
  • rsync gs://apt.stridelabs.ai/pool → ./pool
  • For each tracked package: gh release download → ./pool/main/<l>/<pkg>/
  • apt-ftparchive packages → Packages, gzip
  • apt-ftparchive release → Release
  • gpg --clearsign → InRelease
  • gpg --detach-sign --armor → Release.gpg
  • Upload pool/ first (additive), then dists/ (atomic flip, InRelease last)
  • Set Cache-Control: no-cache on dists/* (belt-and-suspenders for Cloudflare)
  • Smoke test via docker run ubuntu:noble
    │
    ▼
gs://apt.stridelabs.ai/  (public read, Object Versioning enabled)
    │
    ▼
Cloudflare proxy at apt.stridelabs.ai
  • SSL: Full
  • Cache rules: dists/* bypass; pool/* edge-cache 1 month
    │
    ▼
End user runs `apt update && apt install <pkg>`
```

End-to-end latency from `git push --tags` in a source repo to `apt update` showing the new version: ~3–5 minutes.

## Security model

The trust boundary is **GPG signing**, not TLS.

- Every `Release` and `InRelease` file in `dists/noble/` is signed with an ed25519 key whose pubkey lives at `https://apt.stridelabs.ai/pubkey.gpg`.
- Users wire that pubkey into `signed-by=` in their sources list. apt-secure refuses to use any metadata it can't verify against that key.
- The GCS bucket is public-read by design — no secrets in transit, no auth needed.
- Cloudflare uses **Full** (not Strict) SSL because GCS's cert is `*.storage.googleapis.com`, which doesn't match `apt.stridelabs.ai`. Strict would fail the chain check; Full validates the chain but not the hostname. This is acceptable because GPG signing is the actual integrity guarantee.

## Idempotency

The publish workflow is idempotent by construction. Each run:

1. Pulls the current `pool/` from GCS.
2. Re-scans every tracked package's latest GitHub release.
3. Regenerates `Packages`, `Release`, `InRelease` from scratch.
4. Uploads `pool/` first, then `dists/`, with `InRelease` last.

A missed `repository_dispatch` is not catastrophic — the next dispatch (or `workflow_dispatch`) republishes everything anyway. The `client_payload` is logged for observability but ignored for correctness.

## What this is not

- **Not a build system**: source repos build their own debs and attach them to GitHub releases. apt-charliek only repackages.
- **Not multi-distro**: one suite (`noble`), one libadwaita ABI baseline. Add a parallel suite if a future Ubuntu version needs different debs.
- **Not authenticated**: public-read bucket, public-read repo. For private/auth'd packages, [folio](https://github.com/charliek/folio)'s Cloud Run + GCS pattern is the better template.
- **Not mirrored**: single origin. Adding mirroring would mean enabling `Acquire-By-Hash`, generating `by-hash/` directories, and pushing to additional buckets.
