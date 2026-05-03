# GCP Setup

Provisions the GCP resources backing apt-charliek: a public-read GCS bucket, a CI service account with `storage.objectAdmin` on the bucket, and a Workload Identity Federation binding so GitHub Actions can authenticate without a service-account key.

## Prerequisites

- `gcloud` CLI authenticated as a project owner.
- A GCP project with billing enabled. By default the script uses `projects-413401`, the same project as `folio`. Override via `PROJECT_ID` env if needed.
- Folio's WIF pool (`github-pool`) and provider (`github-provider`) may already exist in the project. The script reuses them if present.

## Run the script

```bash
cd ~/projects/apt-charliek
./infra/setup.sh
```

The script is idempotent — re-running on a partially-provisioned project skips already-created resources.

## What it provisions

| Resource | Purpose |
|---|---|
| `gs://apt.stridelabs.ai` | Public-read bucket, Object Versioning enabled (cheap rollback) |
| SA `apt-ci@<project>.iam.gserviceaccount.com` | CI identity for publishing; `roles/storage.objectAdmin` on the bucket only |
| WIF pool `github-pool` (reused if exists) | OIDC pool for GitHub Actions tokens |
| WIF provider `github-provider` (reused if exists) | Restricts to `repository_owner == 'charliek'` |
| `principalSet://.../attribute.repository_owner/charliek` → `apt-ci` | Lets any charliek-owned GitHub repo's Actions runs assume `apt-ci` |
| `allUsers → roles/storage.objectViewer` on bucket | Public read |

The script does **not**:

- Generate the GPG signing key — that lives in [Secrets](../development/secrets.md).
- Set GitHub Actions secrets — the script prints the `gh secret set` commands you need to run afterwards.
- Configure Cloudflare DNS or cache rules — see [Cloudflare Setup](cloudflare-setup.md).

## After the script completes

The script prints a block like:

```
==> Done. GitHub Actions secrets to set on charliek/apt-charliek:

  gh secret set GCP_WIF_PROVIDER --repo charliek/apt-charliek \
    --body 'projects/<num>/locations/global/workloadIdentityPools/github-pool/providers/github-provider'

  gh secret set GCP_SA_EMAIL --repo charliek/apt-charliek \
    --body 'apt-ci@<project>.iam.gserviceaccount.com'
```

Run those commands. Then upload the GPG signing key per [Secrets](../development/secrets.md). After all four secrets are set (`GCP_WIF_PROVIDER`, `GCP_SA_EMAIL`, `APT_SIGNING_KEY`, `APT_SIGNING_KEY_FPR`) the publish workflow can run.

## Healthcheck

The script writes a `healthcheck` object to the bucket and curls it back. If you see `WARNING: healthcheck did not return expected content yet`, IAM propagation may still be in flight — re-run the curl after a minute:

```bash
curl -fsSL https://storage.googleapis.com/apt.stridelabs.ai/healthcheck
```

## Tearing down

The script does not include a teardown path. To remove:

```bash
gcloud storage rm --recursive gs://apt.stridelabs.ai
gcloud storage buckets delete gs://apt.stridelabs.ai
gcloud iam service-accounts delete apt-ci@projects-413401.iam.gserviceaccount.com
```

Don't delete the WIF pool/provider unless folio is also gone — they're shared.
