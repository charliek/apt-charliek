# Local Development

How to develop on apt-charliek without touching real GCS, real GitHub releases, or the real signing key.

## One-time setup

```bash
git clone git@github.com:charliek/apt-charliek.git
cd apt-charliek

# uv handles Python deps for the docs site
uv sync --group docs

# nfpm builds the fixture deb (only needed if regenerating the fixture)
go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest
# or: brew install goreleaser/tap/nfpm

# shellcheck + shfmt for the lint targets
sudo apt install shellcheck
go install mvdan.cc/sh/v3/cmd/shfmt@latest

# (optional) envsecrets pull for the GPG signing key
envsecrets pull
```

`shellcheck` and `shfmt` are the only hard requirements for the `make check` path. The rest are conveniences.

## Common targets

```bash
make help                # list everything
make lint                # shellcheck + shfmt --diff
make docs                # uv run --locked zensical build --strict
make docs-serve          # serve docs at http://127.0.0.1:7070
make publish-fixture     # FIXTURE_MODE publish against the committed fixture
make verify-local        # docker smoke-test the fixture publish
make check               # the full PR-equivalent gauntlet
make clean               # remove generated trees
```

## The fixture publish

`make publish-fixture` runs `scripts/publish.sh` with `FIXTURE_MODE=1`. In that mode:

- An ephemeral GPG key is generated in a fresh `$GNUPGHOME`.
- No GCS sync — `pool/` is whatever you populated locally.
- No GCS upload — `dists/` and `pubkey.gpg` are written to your working directory only.

After it runs, `make verify-local` boots an `ubuntu:noble` container, mounts your working directory at `/repo`, points apt at `file:///repo`, and runs `apt update` + `apt-cache policy hello`. A passing run proves the metadata is well-formed and the signature verifies.

## Iterating on `publish.sh` or `collect-debs.sh`

The fastest iteration loop is local. Avoid pushing branches just to test publish-script changes — `make publish-fixture verify-local` covers the same ground as the CI `fixture-publish` job.

If you need to test against a real GitHub release (rare), set `GH_TOKEN`, run `./scripts/collect-debs.sh` directly to populate `pool/`, then run a fixture publish.

## Testing infra/setup.sh

`infra/setup.sh` is idempotent. The cheapest dry-run is to `set -x` and execute against a scratch project, but for personal dev you can re-run against the real project — already-created resources are skipped.

## Releasing changes

apt-charliek itself is released by merging to `main`. Two workflows fire:

- `publish-pages.yml` — deploys docs if `docs/`, `zensical.toml`, `pyproject.toml`, or `uv.lock` changed. `docs-pr.yml` runs the same strict build on pull requests.
- `ci.yml` — runs the lint + fixture publish on push to main as a safety net.

The actual apt repo publish runs on `repository_dispatch` (from source repos) or `workflow_dispatch` (manual). Pushing to apt-charliek's main does **not** automatically republish the apt repo — fire `workflow_dispatch` if you want to republish after a script change.
