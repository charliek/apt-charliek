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
    - For each tracked package in `packages.yaml`, queries the latest non-pre-release tag and downloads matching `.deb` assets.
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

Each `publish.yml` run rebuilds `Packages` / `Release` / `InRelease` from scratch by re-scanning every tracked package's latest release. Side effects:

- A missed dispatch self-heals on the next dispatch.
- A `workflow_dispatch` "republish now" works without arguments — it picks up any release that landed since the last run.
- Manually deleting a `.deb` from the bucket and re-running publish restores it (collected from the GitHub release).

The `client_payload.package` and `client_payload.tag` fields are logged for observability but ignored by the workflow body.

## Failure modes

| Failure | Cause | Fix |
|---|---|---|
| `latest release vX.Y.Z has no asset matching '<glob>'` | Source repo's `nfpms:` config is broken or asset name pattern changed | Fix the source repo's `.goreleaser.yaml`, cut a new release |
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
