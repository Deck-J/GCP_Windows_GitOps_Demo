#!/usr/bin/env bash
# Create the Dynatrace runtime identity and store an installer token in Google Secret Manager.
# The token is entered interactively and never emitted to GitHub, Git, or command output.
set -Eeuo pipefail

PROJECT_ID="${1:?project id is required}"
DYNATRACE_ENVIRONMENT_URL="${2:?Dynatrace environment URL is required}"
TOKEN_SECRET="${3:-dynatrace-installer-token}"
RUNTIME_SA_NAME="${4:-dynatrace-demo-runtime}"
CLOUD_BUILD_SA="${5:?Cloud Build service account email is required}"

[[ "$DYNATRACE_ENVIRONMENT_URL" =~ ^https://[^/]+/?$ ]] || {
  echo "Dynatrace environment URL must look like https://abc123.live.dynatrace.com"
  exit 2
}
[[ "$TOKEN_SECRET" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "Invalid secret name"; exit 2; }
[[ "$RUNTIME_SA_NAME" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || { echo "Invalid service account name"; exit 2; }
[[ "$CLOUD_BUILD_SA" == *@*.iam.gserviceaccount.com ]] || { echo "Invalid Cloud Build service account email"; exit 2; }

RUNTIME_SA="$RUNTIME_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"

# Refuse non-interactive input so the token is never supplied as a command-line
# argument or echoed into automation logs.
if [[ ! -t 0 ]]; then
  echo "Run this setup interactively so the Dynatrace token can be entered without shell history"
  exit 1
fi
# Read from a terminal without echo so the token cannot leak through command
# history, process arguments, or normal terminal output.
read -rsp "Dynatrace InstallerDownload token: " DYNATRACE_TOKEN
echo
[[ -n "$DYNATRACE_TOKEN" && "$DYNATRACE_TOKEN" != *[[:space:]]* ]] || {
  echo "Token must be non-empty and contain no whitespace"
  exit 2
}

if ! gcloud iam service-accounts describe "$RUNTIME_SA" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$RUNTIME_SA_NAME" \
    --project="$PROJECT_ID" \
    --display-name="Dynatrace demo runtime"
fi

# The installer token is written via stdin; then the local shell variable is
# cleared before IAM bindings and human-readable setup output are produced.
# Create resources idempotently so rerunning setup only rotates the secret value
# and reapplies the narrowly scoped runtime access bindings.
if ! gcloud secrets describe "$TOKEN_SECRET" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud secrets create "$TOKEN_SECRET" --project="$PROJECT_ID" --replication-policy=automatic
fi

printf '%s' "$DYNATRACE_TOKEN" | gcloud secrets versions add "$TOKEN_SECRET" \
  --project="$PROJECT_ID" --data-file=- >/dev/null
unset DYNATRACE_TOKEN

gcloud secrets add-iam-policy-binding "$TOKEN_SECRET" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:$RUNTIME_SA" \
  --role=roles/secretmanager.secretAccessor >/dev/null

gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
  --project="$PROJECT_ID" \
  --member="serviceAccount:$CLOUD_BUILD_SA" \
  --role=roles/iam.serviceAccountUser >/dev/null

cat <<OUTPUT
Dynatrace integration configured.

Set these GitHub Actions repository variables for both deployment workflows:
  DYNATRACE_ENABLED=true
  DYNATRACE_ENVIRONMENT_URL=${DYNATRACE_ENVIRONMENT_URL%/}
  DYNATRACE_TOKEN_SECRET=$TOKEN_SECRET
  DYNATRACE_RUNTIME_SERVICE_ACCOUNT=$RUNTIME_SA
  DYNATRACE_MONITORING_MODE=fullstack
  DYNATRACE_HOST_GROUP=gcp-windows-demo
  DYNATRACE_NETWORK_ZONE=disabled
The token value was stored only in Secret Manager and was not printed.
OUTPUT
