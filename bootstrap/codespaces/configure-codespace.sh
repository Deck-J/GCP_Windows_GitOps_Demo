#!/usr/bin/env bash
# Check local gcloud/GitHub access, select a project configuration, and report missing APIs.
# This script is intentionally read-only for IAM and API enablement.
set -Eeuo pipefail

PROJECT_ID="${1:-${GCP_PROJECT_ID:-}}"
ZONE="${2:-${GCP_ZONE:-us-central1-a}}"
CONFIGURATION="windows-image-demo"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

[[ -n "$PROJECT_ID" ]] || {
  echo "Usage: $0 PROJECT_ID [ZONE]"
  exit 2
}

for command in gcloud gh jq; do
  command -v "$command" >/dev/null 2>&1 || {
    log "[FAIL] Required command is unavailable: $command"
    exit 1
  }
done

ACTIVE_ACCOUNT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | head -1)"
if [[ -z "$ACTIVE_ACCOUNT" ]]; then
  log "[ACTION REQUIRED] Authenticate from the Codespace terminal:"
  echo "  gcloud auth login --no-launch-browser"
  exit 1
fi

if ! gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null 2>&1; then
  log "[FAIL] $ACTIVE_ACCOUNT cannot access GCP project $PROJECT_ID"
  exit 1
fi

if gcloud config configurations describe "$CONFIGURATION" >/dev/null 2>&1; then
  gcloud config configurations activate "$CONFIGURATION" >/dev/null
else
  gcloud config configurations create "$CONFIGURATION" --activate >/dev/null
fi
gcloud config set project "$PROJECT_ID" >/dev/null
gcloud config set compute/zone "$ZONE" >/dev/null

REQUIRED_APIS=(
  cloudbuild.googleapis.com
  compute.googleapis.com
  iap.googleapis.com
  iam.googleapis.com
  iamcredentials.googleapis.com
  secretmanager.googleapis.com
  storage.googleapis.com
  sts.googleapis.com
)

mapfile -t ENABLED_APIS < <(
  gcloud services list --enabled --project="$PROJECT_ID" --format='value(config.name)'
)
MISSING_APIS=()
for api in "${REQUIRED_APIS[@]}"; do
  if ! printf '%s\n' "${ENABLED_APIS[@]}" | grep -Fxq "$api"; then
    MISSING_APIS+=("$api")
  fi
done

log "[PASS] GitHub repository: $(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo 'GitHub CLI access not yet available')"
log "[PASS] GCP account: $ACTIVE_ACCOUNT"
log "[PASS] GCP project: $PROJECT_ID"
log "[PASS] GCP zone: $ZONE"

if (( ${#MISSING_APIS[@]} > 0 )); then
  log "[ACTION REQUIRED] Enable the following APIs before running the demo:"
  printf '  %s\n' "${MISSING_APIS[@]}"
  echo
  printf '  gcloud services enable'
  printf ' %q' "${MISSING_APIS[@]}"
  printf ' --project=%q\n' "$PROJECT_ID"
else
  log "[PASS] All required GCP APIs are enabled"
fi

cat <<MESSAGE

Codespace configuration is ready for manual Cloud Build commands.
Connect the GitHub repository to Cloud Build, then configure triggers with:
  PROJECT_ID=$PROJECT_ID
  ZONE=$ZONE
  BUILD_SERVICE_ACCOUNT=<cloud-build-service-account-email>

Run image and deployment builds with the Cloud Build triggers or gcloud builds submit.
MESSAGE
