#!/usr/bin/env bash
# =============================================================================
# apt-charliek GCP Infrastructure Setup
# =============================================================================
#
# Provisions the GCP resources for apt-charliek's static apt repo:
#   - Public-read GCS bucket at gs://apt.stridelabs.ai
#   - apt-ci service account with storage.objectAdmin on that bucket
#   - Workload Identity Federation binding so GitHub Actions can authenticate
#     without a service-account key (reuses folio's github-pool/provider if
#     they already exist; otherwise creates them).
#
# Read it once, then run it. It is idempotent — re-running on a partially-
# provisioned project skips already-created resources.
#
# Prerequisites:
#   - gcloud CLI authenticated as a project owner
#   - gh CLI authenticated as the apt-charliek repo owner
#   - GCP project with billing enabled
#
# After this script completes:
#   1. Run the printed `gh secret set` commands to populate the apt-charliek
#      repo secrets.
#   2. Configure Cloudflare DNS + cache rules — see the comment block at the
#      bottom of this file or docs/guides/cloudflare-setup.md.
#   3. Trigger publish.yml via workflow_dispatch to do the first publish.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

PROJECT_ID="${PROJECT_ID:-projects-413401}"
REGION="${REGION:-us-central1}"
BUCKET_NAME="${BUCKET_NAME:-apt.stridelabs.ai}"
GITHUB_ORG="${GITHUB_ORG:-charliek}"
GITHUB_REPO="${GITHUB_REPO:-charliek/apt-charliek}"

CI_SA="${CI_SA:-apt-ci}"
WIF_POOL="${WIF_POOL:-github-pool}"
WIF_PROVIDER="${WIF_PROVIDER:-github-provider}"

CI_SA_EMAIL="$CI_SA@$PROJECT_ID.iam.gserviceaccount.com"

echo "==> Configuration"
echo "    PROJECT_ID:   $PROJECT_ID"
echo "    BUCKET:       gs://$BUCKET_NAME"
echo "    CI SA:        $CI_SA_EMAIL"
echo "    WIF pool:     $WIF_POOL"
echo "    GITHUB_REPO:  $GITHUB_REPO"
echo

# -----------------------------------------------------------------------------
# 1. Bucket: create + public-read + object versioning
# -----------------------------------------------------------------------------

echo "==> Bucket"
if gcloud storage buckets describe "gs://$BUCKET_NAME" --project="$PROJECT_ID" \
	>/dev/null 2>&1; then
	echo "    bucket gs://$BUCKET_NAME exists; skipping create"
else
	gcloud storage buckets create "gs://$BUCKET_NAME" \
		--project="$PROJECT_ID" \
		--location="$REGION" \
		--uniform-bucket-level-access
fi

echo "    enabling object versioning (cheap rollback insurance)"
gcloud storage buckets update "gs://$BUCKET_NAME" \
	--versioning >/dev/null

echo "    granting allUsers objectViewer (public read)"
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" \
	--member="allUsers" \
	--role="roles/storage.objectViewer" >/dev/null

# -----------------------------------------------------------------------------
# 2. CI service account
# -----------------------------------------------------------------------------

echo "==> CI service account"
if gcloud iam service-accounts describe "$CI_SA_EMAIL" \
	--project="$PROJECT_ID" >/dev/null 2>&1; then
	echo "    SA $CI_SA_EMAIL exists; skipping create"
else
	gcloud iam service-accounts create "$CI_SA" \
		--display-name="apt-charliek CI" \
		--project="$PROJECT_ID"
fi

echo "    binding storage.objectAdmin on bucket"
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" \
	--member="serviceAccount:$CI_SA_EMAIL" \
	--role="roles/storage.objectAdmin" >/dev/null

# -----------------------------------------------------------------------------
# 3. Workload Identity Federation (reuse folio's pool if present)
# -----------------------------------------------------------------------------

echo "==> Workload Identity Federation"

if gcloud iam workload-identity-pools describe "$WIF_POOL" \
	--location=global --project="$PROJECT_ID" >/dev/null 2>&1; then
	echo "    pool $WIF_POOL exists; skipping create"
else
	gcloud iam workload-identity-pools create "$WIF_POOL" \
		--location=global \
		--project="$PROJECT_ID"
fi

if gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
	--location=global --workload-identity-pool="$WIF_POOL" \
	--project="$PROJECT_ID" >/dev/null 2>&1; then
	echo "    provider $WIF_PROVIDER exists; skipping create"
else
	gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
		--location=global \
		--workload-identity-pool="$WIF_POOL" \
		--issuer-uri="https://token.actions.githubusercontent.com" \
		--attribute-mapping="google.subject=assertion.sub,attribute.repository_owner=assertion.repository_owner" \
		--attribute-condition="assertion.repository_owner == '$GITHUB_ORG'" \
		--project="$PROJECT_ID"
fi

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

echo "    binding apt-ci to WIF pool (workloadIdentityUser)"
gcloud iam service-accounts add-iam-policy-binding "$CI_SA_EMAIL" \
	--project="$PROJECT_ID" \
	--role="roles/iam.workloadIdentityUser" \
	--member="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$WIF_POOL/attribute.repository_owner/$GITHUB_ORG" \
	>/dev/null

# -----------------------------------------------------------------------------
# 4. Health check: write a marker, read it back via the public URL
# -----------------------------------------------------------------------------

echo "==> health check"
echo "ok $(date -u +%FT%TZ)" | gcloud storage cp - "gs://$BUCKET_NAME/healthcheck"
sleep 3
if curl -fsSL "https://storage.googleapis.com/$BUCKET_NAME/healthcheck" |
	grep -q '^ok '; then
	echo "    public read works at https://storage.googleapis.com/$BUCKET_NAME/"
else
	echo "    WARNING: healthcheck did not return expected content yet."
	echo "    Public-read IAM may take a moment to propagate. Re-test with:"
	echo "      curl -fsSL https://storage.googleapis.com/$BUCKET_NAME/healthcheck"
fi

# -----------------------------------------------------------------------------
# 5. Print the GitHub Actions secrets the user needs to set
# -----------------------------------------------------------------------------

WIF_PROVIDER_RESOURCE="projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$WIF_POOL/providers/$WIF_PROVIDER"

cat <<EOF

==> Done. GitHub Actions secrets to set on $GITHUB_REPO:

  gh secret set GCP_WIF_PROVIDER --repo $GITHUB_REPO \\
    --body '$WIF_PROVIDER_RESOURCE'

  gh secret set GCP_SA_EMAIL --repo $GITHUB_REPO \\
    --body '$CI_SA_EMAIL'

  # Generated separately by the GPG setup runbook:
  #   gh secret set APT_SIGNING_KEY     --repo $GITHUB_REPO --body-file .secrets/apt-signing-key.asc
  #   gh secret set APT_SIGNING_KEY_FPR --repo $GITHUB_REPO --body-file .secrets/apt-signing-key.fpr

EOF

# =============================================================================
# Cloudflare configuration (manual; web dashboard)
# =============================================================================
#
# DNS (zone: stridelabs.ai):
#   Type:     CNAME
#   Name:     apt
#   Target:   c.storage.googleapis.com
#   Proxy:    Proxied (orange cloud)  — required for Cloudflare TLS termination
#
# SSL/TLS for apt.stridelabs.ai (zone-level or scoped Configuration Rule):
#   Mode: Full   — not Flexible (HTTP-only origin), not Strict (would fail
#                  because GCS's cert is *.storage.googleapis.com).
#                  GPG signing on the apt metadata is the actual security
#                  boundary; TLS here is opportunistic privacy.
#
# Cache Rules (Rules → Cache Rules):
#   1. apt.stridelabs.ai/dists/*  → Cache eligibility: Bypass cache
#       (apt metadata changes every publish; stale InRelease 404s on apt install)
#   2. apt.stridelabs.ai/pool/*   → Cache eligibility: Eligible
#                                   Edge TTL: 1 month
#                                   Browser TTL: 1 month
#       (debs are content-addressed by version)
#
# After Cloudflare is configured, verify with:
#   curl -I https://apt.stridelabs.ai/dists/noble/InRelease   # cf-cache-status: BYPASS|DYNAMIC
#   curl -I https://apt.stridelabs.ai/pool/                   # 404 is fine; just checks routing
# =============================================================================
