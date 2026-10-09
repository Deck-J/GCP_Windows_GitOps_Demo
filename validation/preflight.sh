#!/usr/bin/env bash
# Read-only readiness check before launching the expensive Windows image/demo workflows.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT_ID="${1:-${GCP_PROJECT_ID:-}}"
ZONE="${2:-${GCP_ZONE:-us-central1-a}}"
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
REQUIRED_GH_VARS=(
  GCP_PROJECT_ID
  GCP_ZONE
  GCP_WIF_PROVIDER
  GCP_WIF_SERVICE_ACCOUNT
  GCP_BUILD_SOURCE_BUCKET
  CLOUD_BUILD_SERVICE_ACCOUNT
)

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
  log "[FAIL] $*"
  exit 1
}

warn() {
  log "[WARN] $*"
}

pass() {
  log "[PASS] $*"
}

[[ -n "$PROJECT_ID" ]] || fail "Usage: $0 PROJECT_ID [ZONE] or set GCP_PROJECT_ID"

for command in gcloud jq bash; do
  command -v "$command" >/dev/null 2>&1 || fail "Required command is unavailable: $command"
done
pass "Required local commands are available"

gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null || fail "Cannot read GCP project $PROJECT_ID"
pass "GCP project is readable: $PROJECT_ID"

mapfile -t ENABLED_APIS < <(gcloud services list --enabled --project="$PROJECT_ID" --format='value(config.name)')
for api in "${REQUIRED_APIS[@]}"; do
  if printf '%s\n' "${ENABLED_APIS[@]}" | grep -Fxq "$api"; then
    pass "API enabled: $api"
  else
    warn "API not enabled: $api"
  fi
done

VERSION_FILE="$(jq -r '.versionFile // "applications/sample/VERSION"' applications/sample/project.json)"
SETUP_SCRIPT="$(jq -r '.setupScript // empty' applications/sample/project.json)"
VALIDATE_SCRIPT="$(jq -r '.validateScript // empty' applications/sample/project.json)"
[[ -f "$VERSION_FILE" ]] || fail "Configured version file is missing: $VERSION_FILE"
[[ -f "$SETUP_SCRIPT" ]] || fail "Configured setup script is missing: $SETUP_SCRIPT"
[[ -f "$VALIDATE_SCRIPT" ]] || fail "Configured validate script is missing: $VALIDATE_SCRIPT"
APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$APP_VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]] || fail "Application version looks invalid: $APP_VERSION"
pass "Project hooks and version are present: $APP_VERSION"

for environment in dev prod; do
  manifest="environments/$environment/deployment.env"
  if grep -nEv '^(#|$|[A-Z_][A-Z0-9_]*=)' "$manifest"; then
    fail "$manifest contains lines that are not simple assignments/comments"
  fi
  # shellcheck disable=SC1090
  source "$manifest"
  [[ "${ACTIVE_COLOR:-}" =~ ^(blue|green)$ ]] || fail "$manifest: ACTIVE_COLOR must be blue or green"
  [[ "${LB_TYPE:-HTTP}" =~ ^(HTTP|TCP)$ ]] || fail "$manifest: LB_TYPE must be HTTP or TCP"
  [[ "${NODE_COUNT:-}" =~ ^[1-9][0-9]*$ ]] || fail "$manifest: NODE_COUNT must be a positive integer"
  if [[ "${BLUE_IMAGE:-}" == "REPLACE_WITH_INITIAL_IMAGE" && -z "${GREEN_IMAGE:-}" ]]; then
    warn "$environment has no real image recorded yet; build an image before deploying"
  fi
  pass "$environment manifest parses with ACTIVE_COLOR=$ACTIVE_COLOR NODE_COUNT=$NODE_COUNT"
  unset ACTIVE_COLOR NODE_COUNT BLUE_IMAGE BLUE_VERSION GREEN_IMAGE GREEN_VERSION NETWORK SUBNET LB_TYPE HEALTH_CHECK_PATH PORT
done

if command -v gh >/dev/null 2>&1; then
  if gh repo view >/dev/null 2>&1; then
    missing=()
    for name in "${REQUIRED_GH_VARS[@]}"; do
      if ! gh variable get "$name" >/dev/null 2>&1; then
        missing+=("$name")
      fi
    done
    if (( ${#missing[@]} > 0 )); then
      warn "Missing GitHub repository variables: ${missing[*]}"
    else
      pass "Required GitHub repository variables exist"
    fi
  else
    warn "GitHub CLI is installed but not authenticated or not inside a GitHub repo"
  fi
else
  warn "GitHub CLI is unavailable; skipped repository variable check"
fi

if gcloud compute zones describe "$ZONE" --project="$PROJECT_ID" >/dev/null 2>&1; then
  pass "Compute zone is readable: $ZONE"
else
  warn "Compute zone is not readable: $ZONE"
fi

pass "Preflight complete; resolve warnings before a live demo"
