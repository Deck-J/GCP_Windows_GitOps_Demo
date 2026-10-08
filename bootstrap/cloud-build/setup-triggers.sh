#!/usr/bin/env bash
# Create native Cloud Build triggers for validation, image builds, and reviewed deployments.
set -Eeuo pipefail

PROJECT_ID="${1:?Usage: $0 PROJECT_ID ZONE BUILD_SERVICE_ACCOUNT_EMAIL}"
ZONE="${2:-us-central1-a}"
BUILD_SERVICE_ACCOUNT="${3:?Usage: $0 PROJECT_ID ZONE BUILD_SERVICE_ACCOUNT_EMAIL}"
CONFIGURATION="windows-image-demo"

for command in gcloud gh; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "[FAIL] Required command is unavailable: $command" >&2
    exit 1
  }
done

[[ "$BUILD_SERVICE_ACCOUNT" == *@*.iam.gserviceaccount.com ]] || {
  echo "[FAIL] BUILD_SERVICE_ACCOUNT must be a service account email" >&2
  exit 2
}

REPOSITORY="$(gh repo view --json owner,name -q '.owner.login + " " + .name')"
read -r REPOSITORY_OWNER REPOSITORY_NAME <<<"$REPOSITORY"

if ! gcloud iam service-accounts describe "$BUILD_SERVICE_ACCOUNT" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "[FAIL] Cloud Build service account does not exist: $BUILD_SERVICE_ACCOUNT" >&2
  exit 1
fi

gcloud config configurations describe "$CONFIGURATION" >/dev/null 2>&1 || \
  gcloud config configurations create "$CONFIGURATION" --no-activate >/dev/null
gcloud config configurations activate "$CONFIGURATION" >/dev/null
gcloud config set project "$PROJECT_ID" >/dev/null
gcloud config set compute/zone "$ZONE" >/dev/null
gcloud services enable cloudbuild.googleapis.com compute.googleapis.com iap.googleapis.com \
  --project="$PROJECT_ID"

create_trigger() {
  local name="$1"
  local build_config="$2"
  local event="$3"
  local included_files="${4:-}"
  local substitutions="${5:-}"
  local trigger_exists=false
  local -a command
  if gcloud builds triggers describe "$name" --project="$PROJECT_ID" \
    --region=global >/dev/null 2>&1; then
    trigger_exists=true
    command=(
      gcloud builds triggers update github "$name"
      --project="$PROJECT_ID"
      --region=global
      --build-config="$build_config"
      --service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SERVICE_ACCOUNT}"
    )
    echo "[INFO] Updating Cloud Build trigger: $name"
  else
    command=(
      gcloud builds triggers create github
      --name="$name"
      --project="$PROJECT_ID"
      --region=global
      --repo-owner="$REPOSITORY_OWNER"
      --repo-name="$REPOSITORY_NAME"
      --build-config="$build_config"
      --service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SERVICE_ACCOUNT}"
    )
  fi

  if [[ "$event" == "pull-request" ]]; then
    if [[ "$trigger_exists" == "true" ]]; then
      command+=(--pull-request-pattern='^main$' --comment-control=COMMENTS_DISABLED)
    else
      command+=(--pull-request --branch-pattern='^main$' --comment-control=COMMENTS_DISABLED)
    fi
  else
    local trigger_substitutions="_ZONE=$ZONE"
    [[ -n "$substitutions" ]] && trigger_substitutions+=",${substitutions}"
    command+=(--branch-pattern='^main$' --included-files="$included_files")
    if [[ "$trigger_exists" == "true" ]]; then
      command+=(--update-substitutions="$trigger_substitutions")
    else
      command+=(--substitutions="$trigger_substitutions")
    fi
  fi

  "${command[@]}"
}

create_trigger "validate-pull-requests" "cloudbuild/cloudbuild-validate.yaml" \
  "pull-request"
create_trigger "build-windows-image" "cloudbuild/cloudbuild-image.yaml" "push" \
  "applications/sample/**,infrastructure/image/**,cloudbuild/cloudbuild-image.yaml"
create_trigger "reconcile-development-demo" "cloudbuild/cloudbuild-deploy.yaml" "push" \
  "environments/dev/deployment.env,infrastructure/deployment/**,infrastructure/networking/**,integrations/dynatrace/**,cloudbuild/cloudbuild-deploy.yaml" \
  "_APP_NAME=dev-iis-demo,_DEPLOYMENT_MANIFEST=environments/dev/deployment.env"
create_trigger "reconcile-production-demo" "cloudbuild/cloudbuild-deploy.yaml" "push" \
  "environments/prod/deployment.env,infrastructure/deployment/**,infrastructure/networking/**,integrations/dynatrace/**,cloudbuild/cloudbuild-deploy.yaml" \
  "_APP_NAME=prod-iis-demo,_DEPLOYMENT_MANIFEST=environments/prod/deployment.env"

cat <<OUTPUT
[PASS] Cloud Build triggers configured
Repository: ${REPOSITORY_OWNER}/${REPOSITORY_NAME}
Project: $PROJECT_ID
Zone: $ZONE
Build service account: $BUILD_SERVICE_ACCOUNT

Connect this repository to Cloud Build in the Google Cloud Console before running this script.
Grant the build service account the Compute Engine, IAP, logging, and optional Secret Manager
permissions documented in README.md. Configure trigger substitutions for non-default options.
OUTPUT