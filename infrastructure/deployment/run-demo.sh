#!/usr/bin/env bash
# Run the blue/green deployment demo, keep its validated endpoint available for a viewing window,
# then tear down runtime resources while preserving the original deployment result.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PROJECT_ID="${1:?project id is required}"
ZONE="${2:?zone is required}"
APP_NAME="${3:?application name is required}"
TEARDOWN_DELAY_SECONDS="${4:-600}"
DYNATRACE_ENABLED="${5:-false}"
DYNATRACE_ENVIRONMENT_URL="${6:-disabled}"
DYNATRACE_TOKEN_SECRET="${7:-disabled}"
DYNATRACE_RUNTIME_SERVICE_ACCOUNT="${8:-disabled}"
DYNATRACE_MONITORING_MODE="${9:-fullstack}"
DYNATRACE_HOST_GROUP="${10:-gcp-windows-demo}"
DYNATRACE_NETWORK_ZONE="${11:-disabled}"
DEPLOYMENT_MANIFEST="${12:-environments/prod/deployment.env}"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

countdown() {
  local remaining="$1"
  local interval
  while (( remaining > 0 )); do
    log "[VIEWING WINDOW] Teardown in ${remaining} seconds"
    interval=60
    (( remaining < interval )) && interval="$remaining"
    sleep "$interval"
    remaining=$((remaining - interval))
  done
}

if ! [[ "$APP_NAME" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]] || (( ${#APP_NAME} > 32 )); then
  log "[FAIL] APP_NAME must be a lowercase GCP-safe name of at most 32 characters"
  exit 2
fi

if ! [[ "$TEARDOWN_DELAY_SECONDS" =~ ^[0-9]+$ ]]; then
  log "[FAIL] TEARDOWN_DELAY_SECONDS must be a non-negative integer"
  exit 2
fi
[[ -f "$DEPLOYMENT_MANIFEST" ]] || {
  log "[FAIL] Deployment manifest does not exist: $DEPLOYMENT_MANIFEST"
  exit 2
}

log "[DEMO 1/5] Start blue/green deployment and application validation"
set +e
bash infrastructure/deployment/deploy-blue-green.sh \
  "$PROJECT_ID" "$ZONE" "$APP_NAME" \
  "$DYNATRACE_ENABLED" "$DYNATRACE_ENVIRONMENT_URL" \
  "$DYNATRACE_TOKEN_SECRET" "$DYNATRACE_RUNTIME_SERVICE_ACCOUNT" \
  "$DYNATRACE_MONITORING_MODE" "$DYNATRACE_HOST_GROUP" \
  "$DYNATRACE_NETWORK_ZONE" "$DEPLOYMENT_MANIFEST"
DEPLOY_STATUS=$?
set -e

if [[ "$DEPLOY_STATUS" -eq 0 ]]; then
  log "[DEMO 2/5] [PASS] Application deployment and validation succeeded"
  log "DEMO_DEPLOY_STATUS=SUCCESS"
else
  log "[DEMO 2/5] [FAIL] Application deployment or validation failed with exit code $DEPLOY_STATUS"
  log "DEMO_DEPLOY_STATUS=FAILURE"
fi

log "[DEMO 3/5] Keep the environment available for ${TEARDOWN_DELAY_SECONDS} seconds"
countdown "$TEARDOWN_DELAY_SECONDS"

log "[DEMO 4/5] Tear down this environment's blue/green worker nodes"
set +e
bash infrastructure/deployment/teardown-demo.sh "$PROJECT_ID" "$ZONE" "$APP_NAME"
TEARDOWN_STATUS=$?
set -e

if [[ "$DEPLOY_STATUS" -ne 0 ]]; then
  if [[ "$TEARDOWN_STATUS" -eq 0 ]]; then
    log "DEMO_TEARDOWN_STATUS=SUCCESS"
  else
    log "DEMO_TEARDOWN_STATUS=FAILURE"
  fi
  log "[DEMO 5/5] [FAIL] Teardown ran after a failed demo; preserving the deployment failure status"
  exit "$DEPLOY_STATUS"
fi

if [[ "$TEARDOWN_STATUS" -ne 0 ]]; then
  log "DEMO_TEARDOWN_STATUS=FAILURE"
  log "[DEMO 5/5] [FAIL] Application validation passed, but runtime teardown was incomplete"
  exit "$TEARDOWN_STATUS"
fi

log "DEMO_TEARDOWN_STATUS=SUCCESS"
log "[DEMO 5/5] [PASS] Demo completed and all runtime resources were removed"
