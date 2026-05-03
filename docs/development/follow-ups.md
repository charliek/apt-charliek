# Known Follow-ups

Tracked technical debt and deferred improvements. None of these block v1; each is a deliberate scope cut documented so future-us doesn't forget.

## 1. Tighten WIF principal scope to a single repository

**Current state:** the Workload Identity Federation binding for `apt-ci` uses `attribute.repository_owner == "charliek"`, which means any GitHub Actions run in any `charliek`-owned repository can impersonate the `apt-ci` service account. Blast radius today: only `charliek` repos exist and both this repo and `folio` are owned by Charlie, so the practical exposure is unchanged from "Charlie's GitHub account is the trust boundary."

**Better state:** the binding should use `attribute.repository == "charliek/apt-charliek"` so only this exact repo can impersonate. Per [GCP WIF best practices](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines), this is the recommended scope for repo-specific publish pipelines.

**Why deferred:** the `github-pool/github-provider` is shared with [folio](https://github.com/charliek/folio). Implementing this change requires:

1. Adding `attribute.repository=assertion.repository` to the existing provider's attribute mapping (additive — doesn't break folio because folio's principalSet still uses `repository_owner`).
2. Creating a new IAM binding on `apt-ci` using `attribute.repository/charliek/apt-charliek` instead of `attribute.repository_owner/charliek`.
3. Removing the old broad binding on `apt-ci`.
4. Updating `infra/setup.sh` and `docs/guides/gcp-setup.md` to describe the tighter scope.

This is its own PR with a careful test plan, not a v1 line item.

**Tracking:** open a GitHub issue when ready to act.

## 2. Generate `apt-ftparchive.conf` from `packages.yaml` at runtime

**Current state:** `apt-ftparchive.conf` hardcodes `Suite: noble`, `Components: main`, and `Architectures: amd64 arm64`. `packages.yaml` and `publish.sh` treat the same fields as configurable. If we ever change `packages.yaml` (e.g., add `oracular` as a parallel suite, or drop `arm64`), the config goes stale and the published `Release` file references metadata that doesn't match `packages.yaml`.

**Better state:** either

- generate the conf at runtime in `publish.sh` from `packages.yaml`, or
- pass the relevant fields via `apt-ftparchive -o APT::FTPArchive::Release::Suite="$suite"` and drop the static conf.

**Why deferred:** for v1 we have a single suite + single component + two arches. Drift risk is real but not yet observed. When we add a second suite (likely the next Ubuntu LTS release), do this clean-up at the same time.

## 3. Eliminate hardcoded `pool/main` paths in `publish.sh`

**Current state:** `publish.sh` reads `suite`, `component`, and `arches` from `packages.yaml` and uses them in some places, but the pool path `pool/main` is still hardcoded in the `apt-ftparchive packages` invocation. If `component` ever changes to anything other than `main`, layout and metadata will diverge.

**Better state:** thread `$component` through the pool path so `packages.yaml` is the single source of truth for layout.

**Why deferred:** same rationale as #2 — single component for v1, low immediate value.

## 4. (Future) Garbage-collect old debs from `pool/`

**Current state:** every `.deb` ever published stays in `pool/` indefinitely. There is no GC for old versions when a source repo cuts a new release.

**Better state:** publish.sh keeps the latest N versions per package and removes older ones from the bucket.

**Why deferred:** the bucket is cheap and the dataset is tiny. Revisit if `pool/` ever exceeds a few hundred MB or apt update times become noticeable.

## 5. Tighten Cloudflare SSL/TLS to Full for `apt.stridelabs.ai`

**Current state:** the `stridelabs.ai` zone-level SSL/TLS mode is set to **Flexible** because other services on the zone require it. That makes Cloudflare → GCS happen over plain HTTP. User → Cloudflare is still HTTPS.

**Better state:** scope a Configuration Rule (Rules → Configuration Rules → action: SSL) to `Hostname equals "apt.stridelabs.ai"` and set SSL to **Full**. That gives end-to-end HTTPS without changing the zone-wide setting that other services depend on.

**Why deferred:** the per-hostname SSL override is buried in Cloudflare's UI and only some plan tiers expose it cleanly. The actual integrity boundary for the apt repo is GPG signing on the metadata, not TLS — apt-secure refuses anything that doesn't verify against the pubkey, regardless of transport. Flexible mode is operationally fine; this is "defense in depth" at the origin leg. Revisit when convenient.

## 6. (Future) Add by-hash directories for atomic mirror reads

**Current state:** `apt-ftparchive.conf` does not enable `DoByHash`, so no `by-hash/<algo>/<digest>` directories are emitted alongside `Packages` files.

**Better state:** with `Acquire-By-Hash: yes` in the `Release` file and on-disk `by-hash/` trees, mirror clients can fetch metadata by content-addressed digest, eliminating any race window during the publish-upload sequence.

**Why deferred:** single origin (no mirrors), atomic upload order with `InRelease` last, Cloudflare bypasses cache on `dists/*`. The race window is negligible. Revisit if we ever add mirrors.
