# Release Flow

What happens when a source repo cuts a tagged release.

## The full chain

1. **Developer**: `git tag v1.4.0 && git push --tags` in `charliek/prox`.
2. **prox/.github/workflows/release.yaml** fires on the new tag:
    - `goreleaser release --clean` builds the binaries.
    - Existing `archives:` block produces `prox_linux_amd64.tar.gz` etc.
    - Existing `brews:` block commits a new `Formula/prox.rb` to `charliek/homebrew-tap` (uses `HOMEBREW_TAP_TOKEN`).
    - New `nfpms:` block produces `prox_1.4.0_amd64.deb` and `prox_1.4.0_arm64.deb`.
    - All artifacts attach to the GitHub Release at `https://github.com/charliek/prox/releases/tag/v1.4.0`.
    - Final step fires `repository_dispatch` event_type=`publish` at `charliek/apt-charliek` (uses `APT_DISPATCH_TOKEN`).
3. **apt-charliek/.github/workflows/publish.yml** wakes up:
    - WIF auth to GCP.
    - Imports `APT_SIGNING_KEY` into an ephemeral keyring.
    - rsyncs the existing `pool/` from `gs://apt.stridelabs.ai/pool/`.
    - For each tracked package in `packages.yaml`, scans recent non-pre-release releases newest-first and downloads the matching `.deb` assets from the newest release that carries them (see [Selective releases](#selective-releases-newest-release-with-a-matching-asset)).
    - Generates per-arch `Packages` and `Packages.gz` via `apt-ftparchive packages`.
    - Generates `Release` via `apt-ftparchive release`.
    - Signs `InRelease` (clearsigned) and `Release.gpg` (detached, armored).
    - Uploads `pool/` first (additive), then `dists/` (atomic flip; `InRelease` last).
    - Stamps `Cache-Control: no-cache` on `dists/**` objects.
    - Smoke-tests via `docker run ubuntu:noble apt update`.
4. **End user** runs `sudo apt update && sudo apt upgrade prox` and gets v1.4.0.

Wall-clock: typically 3–5 minutes from `git push --tags` to user-visible.

## Watching a release land

After tag-push:

| Tab | URL |
|---|---|
| Source release | `https://github.com/charliek/prox/actions` |
| GH release page | `https://github.com/charliek/prox/releases/tag/v1.4.0` |
| Apt publish | `https://github.com/charliek/apt-charliek/actions/workflows/publish.yml` |
| Smoke test output | inside the apt-charliek run, last step |

The dispatch step in `release.yaml` emits a `::notice::` annotation linking directly to the apt-charliek Actions tab, so you don't have to navigate manually.

## Idempotency

Each `publish.yml` run rebuilds `Packages` / `Release` / `InRelease` from scratch by re-scanning every tracked package's recent releases for the newest one carrying a matching `.deb`. Side effects:

- A missed dispatch self-heals on the next dispatch.
- A `workflow_dispatch` "republish now" works without arguments — it picks up any release that landed since the last run.
- Manually deleting a `.deb` from the bucket and re-running publish restores it (collected from the GitHub release).

The `client_payload.package` and `client_payload.tag` fields are logged for observability but ignored by the workflow body.

## Selective releases: newest release with a matching asset

Some source repos (notably `charliek/shed`, post-monorepo-consolidation) ship
**selective releases**: a single tag family carries different subsets of
packages per release — a server-only tag has no `shed-desktop_*.deb`, a
desktop-only tag has no `shed-server_*.deb`. Because all components share one tag
family, a tag-pattern filter can't tell them apart.

`collect-debs.sh` therefore resolves each package to the **newest release that
actually contains a matching asset**, not simply the latest release:

1. List recent releases (`gh release list --limit 30`, prerelease-filtered) newest-first.
2. For each candidate, query only its asset *names* and stop at the first release whose assets match the package's glob.
3. Download the `.deb` from that release; log the resolved tag, and note explicitly when the scan walked past newer releases that lacked the asset.

The scan is bounded and short-circuits at the first match, so the common case
(newest release carries the asset) costs one extra API call. If **no** release in
the scan window has a matching asset, an `optional: true` entry skips with a
warning; a required entry fails the run. See `charliek/shed`
`docs/discovery/monorepo-consolidation.md` §4.4 for the motivating design.

## Failure modes

| Failure | Cause | Fix |
|---|---|---|
| `no release in the last N on <repo> has an asset matching '<glob>'` | No recent release of the source repo carries a matching `.deb` (broken `nfpms:` config, renamed asset, or the package hasn't shipped its first Linux `.deb`) | Fix the source repo's `.goreleaser.yaml`, cut a new release — or mark the entry `optional: true` if it legitimately has no `.deb` yet |
| WIF auth error in publish job | GCP_WIF_PROVIDER or GCP_SA_EMAIL secret wrong | Re-run `infra/setup.sh`, copy the printed values, `gh secret set` |
| `gpg: signing failed: No secret key` | APT_SIGNING_KEY_FPR doesn't match the imported key | Re-export `.secrets/apt-signing-key.fpr` and update the GH secret |
| `apt update` fails with "BADSIG" or "NO_PUBKEY" in user smoke test | Pubkey on the bucket is stale (post-rotation, before users re-fetch) | Users re-curl `pubkey.gpg`; or republish to refresh |
| `apt update` fails with "Hash Sum mismatch" | Cloudflare cache rule for `dists/*` is missing or wrong | Check Cache Rules, ensure `dists/*` is set to Bypass cache |

## What the developer does NOT need to do per release

- Touch apt-charliek (no PR, no manual step).
- Manually upload anything to GCS.
- Rotate or sign anything.
- Update `packages.yaml` (only on first onboarding of a new package).

The release in the source repo is the only action; everything downstream is automated.
