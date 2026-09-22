#!/usr/bin/env bash
# One-time bootstrap for GitHub OIDC trust, IAM, APIs, and repository variables.
# Run locally with an administrator identity; later builds use short-lived OIDC credentials.
set -Eeuo pipefail

PROJECT_ID="${1:?Usage: $0 PROJECT_ID [ZONE]}"
ZONE="${2:-us-central1-a}"
POOL_ID="github-actions"
PROVIDER_ID="github"
SERVICE_ACCOUNT_NAME="github-actions"
CONFIGURATION="windows-image-demo"

for command in gcloud gh jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[FAIL] Required command is unavailable: $command" >&2
    exit 1
  }
done

REPOSITORY="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
GITHUB_SERVICE_ACCOUNT="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud config configurations describe "$CONFIGURATION" >/dev/null 2>&1 || \
  gcloud config configurations create "$CONFIGURATION" --no-activate >/dev/null
gcloud config configurations activate "$CONFIGURATION" >/dev/null
gcloud config set project "$PROJECT_ID" >/dev/null
gcloud config set compute/zone "$ZONE" >/dev/null

gcloud services enable \
  cloudbuild.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  secretmanager.googleapis.com \
  storage.googleapis.com \
  sts.googleapis.com \
  --project="$PROJECT_ID"

if ! gcloud iam service-accounts describe "$GITHUB_SERVICE_ACCOUNT" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
    --project="$PROJECT_ID" \
    --display-name="GitHub Actions Cloud Build submitter"
fi

if ! gcloud iam workload-identity-pools describe "$POOL_ID" \
  --project="$PROJECT_ID" --location=global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$POOL_ID" \
    --project="$PROJECT_ID" --location=global \
    --display-name="GitHub Actions"
fi

if ! gcloud iam workload-identity-pools providers describe "$PROVIDER_ID" \
  --project="$PROJECT_ID" --location=global \
  --workload-identity-pool="$POOL_ID" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_ID" \
    --project="$PROJECT_ID" --location=global \
    --workload-identity-pool="$POOL_ID" \
    --display-name="GitHub Actions OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="attribute.repository == '${REPOSITORY}'"
fi

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$GITHUB_SERVICE_ACCOUNT" \
  --role=roles/cloudbuild.builds.editor >/dev/null
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$GITHUB_SERVICE_ACCOUNT" \
  --role=roles/serviceusage.serviceUsageConsumer >/dev/null

gcloud iam service-accounts add-iam-policy-binding "$GITHUB_SERVICE_ACCOUNT" \
  --project="$PROJECT_ID" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/attribute.repository/${REPOSITORY}" \
  --role=roles/iam.workloadIdentityUser >/dev/null

WIF_PROVIDER="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}"
gh variable set GCP_PROJECT_ID --body "$PROJECT_ID"
gh variable set GCP_ZONE --body "$ZONE"
gh variable set GCP_WIF_PROVIDER --body "$WIF_PROVIDER"
gh variable set GCP_SERVICE_ACCOUNT --body "$GITHUB_SERVICE_ACCOUNT"
gh variable set VS_INSTALL_MODE --body "web-community"
gh variable set VS_EDITION --body "community"
gh variable set VS_MEDIA_URI --body "gs://unused/vs2022-community-layout.iso"
gh variable set VS_PRODUCT_KEY_SECRET --body "unused"
gh variable set BUILDER_SERVICE_ACCOUNT --body "unused"
gh variable set DYNATRACE_ENABLED --body "false"
gh variable set DYNATRACE_ENVIRONMENT_URL --body "disabled"
gh variable set DYNATRACE_TOKEN_SECRET --body "disabled"
gh variable set DYNATRACE_RUNTIME_SERVICE_ACCOUNT --body "disabled"
gh variable set DYNATRACE_MONITORING_MODE --body "fullstack"
gh variable set DYNATRACE_HOST_GROUP --body "gcp-windows-demo"
gh variable set DYNATRACE_NETWORK_ZONE --body "disabled"

cat <<OUTPUT
[PASS] GitHub Actions bootstrap complete
Repository: $REPOSITORY
Project: $PROJECT_ID
Zone: $ZONE
Service account: $GITHUB_SERVICE_ACCOUNT
WIF provider: $WIF_PROVIDER

The GitHub Actions workflows can now authenticate without a JSON key.
The default workflow path uses web-community and Community edition.
OUTPUT