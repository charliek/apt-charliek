# Adding a Package

Onboarding a new project to apt-charliek is a contract: the source repo produces a `.deb` on every release and notifies apt-charliek; apt-charliek picks it up and republishes the apt metadata.

## Prerequisites

The source repo must have:

- A GitHub Actions release workflow that fires on tag push.
- The ability to attach assets to the GitHub Release. GoReleaser does this automatically.

## Step 1: Produce a `.deb` on every release

If the source repo uses GoReleaser, add an `nfpms:` block to its `.goreleaser.yaml`. Minimal CLI form:

```yaml
nfpms:
  - id: <project>-deb
    package_name: <project>
    file_name_template: "<project>_{{ .Version }}_{{ .Arch }}"
    vendor: charliek
    homepage: "https://github.com/charliek/<project>"
    maintainer: "Charlie Knudsen <charlie.knudsen@gmail.com>"
    description: "<one-line description>"
    license: MIT
    formats: [deb]
    bindir: /usr/local/bin
    ids: [<project>]
```

For a worked example with config files, systemd units, and post-install hooks, see [`charliek/shed/.goreleaser.yaml`](https://github.com/charliek/shed/blob/main/.goreleaser.yaml) — the `nfpms:` block at the bottom.

## Step 2: Add a `release-snapshot` CI job (recommended)

In the source repo's PR CI, add a job that runs `goreleaser release --snapshot --clean` and asserts the deb is well-formed. This catches `nfpms:` regressions before merge.

```yaml
release-snapshot:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v6
    - uses: actions/setup-go@v6
      with:
        go-version-file: go.mod
    - uses: goreleaser/goreleaser-action@v7
      with:
        version: latest
        args: release --snapshot --clean
    - run: |
        ls dist/<project>_*_linux_amd64.deb
        dpkg-deb --info dist/<project>_*_linux_amd64.deb
```

## Step 3: Add the dispatch step to the release workflow

Append a final step to the source repo's `release.yaml`:

```yaml
- name: Trigger apt-charliek publish
  if: success()
  run: |
    gh api repos/charliek/apt-charliek/dispatches \
      --method POST \
      -f event_type=publish \
      -F "client_payload[package]=<project>" \
      -F "client_payload[tag]=${{ github.ref_name }}"
    echo "::notice::Watch publish at https://github.com/charliek/apt-charliek/actions"
  env:
    GH_TOKEN: ${{ secrets.APT_DISPATCH_TOKEN }}
```

`APT_DISPATCH_TOKEN` is a fine-grained PAT scoped to `charliek/apt-charliek` only with `Contents: write`. Add it as a repo secret on the source repo. The existing `HOMEBREW_TAP_TOKEN` is not reused — the two tokens have non-overlapping scopes for blast-radius reasons.

## Step 4: Add an entry to `packages.yaml`

In `charliek/apt-charliek`:

```yaml
packages:
  - name: <project>           # the deb Package: name (matches nfpm package_name)
    repo: charliek/<project>  # github org/repo
    glob: "<project>_*.deb"   # asset pattern on the GH release
    include_prerelease: false
```

See [`packages.yaml` reference](../reference/packages-yaml.md) for the full schema.

## Step 5: Cut a release

```bash
cd <source-repo>
git tag v0.1.0
git push --tags
```

Watch the chain:

1. Source repo's `release.yaml` runs (GoReleaser + dispatch).
2. apt-charliek's `publish.yml` lights up immediately.
3. After ~3 minutes, `apt update && apt-cache madison <project>` shows the new version.

If the publish workflow fails because the GitHub release has no matching deb asset, fix the source repo's `nfpms:` config and cut a new release. The publish is idempotent — it'll pick up the corrected asset on the next dispatch.
