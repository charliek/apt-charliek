# `packages.yaml` Reference

`packages.yaml` is the canonical list of tracked packages. The publish workflow reads it on every run; adding or removing an entry plus a workflow_dispatch is sufficient to onboard or retire a package.

## Top-level fields

| Field | Type | Default | Description |
|---|---|---|---|
| `suite` | string | `noble` | apt suite name; matches the `Suite:` and `Codename:` in the `Release` file. |
| `component` | string | `main` | apt component name. apt-charliek ships only `main` for v1. |
| `architectures` | list | `[amd64, arm64]` | Architectures to generate `Packages` files for. Empty `Packages` is fine for arches with no debs. |
| `origin` | string | `charliek` | `Origin:` field in the `Release` file. |
| `label` | string | `charliek apt repo` | `Label:` field in the `Release` file. |
| `description` | string | (empty) | `Description:` field in the `Release` file. |
| `packages` | list | required | Per-package entries; see below. |

## Per-package fields

| Field | Type | Required | Description |
|---|---|---|---|
| `name` | string | yes | The deb's `Package:` name — must match the source repo's nfpm `package_name`. |
| `repo` | string | yes | GitHub `<owner>/<repo>` to fetch releases from. |
| `glob` | string | no | Asset filename pattern. Default `<name>_*.deb`. Any standard glob works. |
| `include_prerelease` | bool | no | Default `false`. When `false`, releases marked as pre-release in GitHub are skipped. |

## Example

```yaml
suite: noble
component: main
architectures: [amd64, arm64]
origin: charliek
label: charliek apt repo
description: "Debian/Ubuntu apt repository for charliek open-source projects"

packages:
  - name: prox
    repo: charliek/prox
    glob: "prox_*.deb"
    include_prerelease: false
  - name: shed-server
    repo: charliek/shed
    glob: "shed-server_*.deb"
    include_prerelease: false
  - name: envsecrets
    repo: charliek/envsecrets
    glob: "envsecrets_*.deb"
    include_prerelease: false
```

## Failure modes

| Situation | Behavior |
|---|---|
| Package's repo has zero releases | Skipped silently. Legitimate state for a freshly-onboarded entry whose first release hasn't shipped. |
| Package's *latest* release has no asset matching `glob` | Hard fail. Indicates a regression in the source repo's `nfpms:` config. Re-cut the release with the fix. |
| Glob matches multiple debs (e.g. amd64 + arm64) | All are downloaded into `pool/main/<l>/<name>/`. apt-ftparchive sorts them per-arch when generating `Packages`. |
| Source repo's release is pre-release and `include_prerelease: false` | Skipped. The next non-pre-release wins. |
