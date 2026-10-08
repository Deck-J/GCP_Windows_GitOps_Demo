#!/usr/bin/env bash
# Reconcile one environment's GitOps manifest into a validated group of private IIS workers.
# Day-0 load-balancer resources persist; run-demo.sh removes the temporary runtime resources.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PROJECT_ID="${1:?project id is required}"
ZONE="${2:?zone is required}"
APP_NAME="${3:?application name is required}"
DYNATRACE_ENABLED="${4:-false}"
DYNATRACE_ENVIRONMENT_URL="${5:-disabled}"
DYNATRACE_TOKEN_SECRET="${6:-disabled}"
DYNATRACE_RUNTIME_SERVICE_ACCOUNT="${7:-disabled}"
DYNATRACE_MONITORING_MODE="${8:-fullstack}"
DYNATRACE_HOST_GROUP="${9:-gcp-windows-demo}"
DYNATRACE_NETWORK_ZONE="${10:-disabled}"
MANIFEST="${11:-environments/prod/deployment.env}"
[[ -f "$MANIFEST" ]] || { printf '[FAIL] Deployment manifest does not exist: %s\n' "$MANIFEST" >&2; exit 2; }
PROJECT_HEALTH_PATH="$(jq -r '.healthPath // "/health.html"' applications/sample/project.json)"
PROJECT_HEALTH_PORT="$(jq -r '.healthPort // 80' applications/sample/project.json)"
NETWORK="${NETWORK:-default}"
SUBNET="${SUBNET:-default}"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

deploy_stage() {
  log "[DEPLOY $1/6] $2"
}

# This file is reviewed in Git before execution and contains assignments only.
# shellcheck disable=SC1090
source "$MANIFEST"
NETWORK="${NETWORK:-default}"
SUBNET="${SUBNET:-default}"
LB_TYPE="${LB_TYPE:-HTTP}"
HEALTH_CHECK_PATH="${HEALTH_CHECK_PATH:-$PROJECT_HEALTH_PATH}"
PORT="${PORT:-$PROJECT_HEALTH_PORT}"

if [[ "${ACTIVE_COLOR:-}" != "blue" && "${ACTIVE_COLOR:-}" != "green" ]]; then
  log "[FAIL] ACTIVE_COLOR must be blue or green"
  exit 1
fi

ACTIVE_IMAGE_VAR="${ACTIVE_COLOR^^}_IMAGE"
ACTIVE_VERSION_VAR="${ACTIVE_COLOR^^}_VERSION"
ACTIVE_IMAGE="${!ACTIVE_IMAGE_VAR:-}"
ACTIVE_VERSION="${!ACTIVE_VERSION_VAR:-}"
[[ -n "$ACTIVE_IMAGE" && -n "$ACTIVE_VERSION" ]] || { log "[FAIL] Active image and version are required"; exit 1; }

HEALTH_CHECK="${APP_NAME}-health"
BACKEND="${APP_NAME}-backend"
ADDRESS="${APP_NAME}-ip"
VERSION_TOKEN="$(printf '%s' "$ACTIVE_VERSION" | tr '[:upper:].+_' '[:lower:]---' | tr -cd 'a-z0-9-' | cut -c1-10)"
IMAGE_TOKEN="$(basename "$ACTIVE_IMAGE" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-' | tail -c 11)"
TARGET_GROUP="${APP_NAME}-${ACTIVE_COLOR}-n${MIG_SIZE}-${VERSION_TOKEN}-${IMAGE_TOKEN}"
TARGET_GROUP="$(printf '%s' "$TARGET_GROUP" | cut -c1-60 | sed 's/-$//')"
MIG_SIZE="${NODE_COUNT:-}"
[[ "$MIG_SIZE" =~ ^[1-9][0-9]*$ ]] || { log "[FAIL] NODE_COUNT must be a positive integer in $MANIFEST"; exit 1; }
TARGET_VMS=()
for ((node_index = 1; node_index <= MIG_SIZE; node_index++)); do
  TARGET_VMS+=("$(printf '%s-%02d' "$TARGET_GROUP" "$node_index")")
done

exists() {
  gcloud "$@" --project="$PROJECT_ID" >/dev/null 2>&1
}

validate_dynatrace_settings() {
  [[ "$DYNATRACE_ENABLED" =~ ^(true|false)$ ]] || { log "[FAIL] DYNATRACE_ENABLED must be true or false"; return 1; }
  [[ "$DYNATRACE_ENABLED" == "false" ]] && return 0

  [[ "$DYNATRACE_ENVIRONMENT_URL" =~ ^https://[^/]+/?$ ]] || { log "[FAIL] Invalid Dynatrace environment URL"; return 1; }
  [[ "$DYNATRACE_TOKEN_SECRET" =~ ^[A-Za-z0-9_-]+$ ]] || { log "[FAIL] Invalid Dynatrace token secret name"; return 1; }
  [[ "$DYNATRACE_RUNTIME_SERVICE_ACCOUNT" == *@*.iam.gserviceaccount.com ]] || { log "[FAIL] Invalid Dynatrace runtime service account"; return 1; }
  [[ "$DYNATRACE_MONITORING_MODE" =~ ^(fullstack|infra-only|discovery)$ ]] || { log "[FAIL] Invalid Dynatrace monitoring mode"; return 1; }
  [[ "$DYNATRACE_HOST_GROUP" =~ ^[A-Za-z0-9_.-]{1,100}$ && "$DYNATRACE_HOST_GROUP" != dt.* ]] || { log "[FAIL] Invalid Dynatrace host group"; return 1; }
  if [[ "$DYNATRACE_NETWORK_ZONE" != "disabled" ]]; then
    [[ "$DYNATRACE_NETWORK_ZONE" =~ ^[A-Za-z0-9_.-]{1,256}$ ]] || { log "[FAIL] Invalid Dynatrace network zone"; return 1; }
  fi
}

wait_for_dynatrace() {
  local vm_name="$1"
  local deadline=$((SECONDS + 600))
  local output

  log "[DYNATRACE] Waiting for $vm_name to report DYNATRACE_READY"
  while (( SECONDS < deadline )); do
    output="$(gcloud compute instances get-serial-port-output "$vm_name" \
      --project="$PROJECT_ID" --zone="$ZONE" --port=1 2>/dev/null || true)"
    if grep -Fq 'DYNATRACE_FAILED:' <<<"$output"; then
      log "[FAIL] Dynatrace initialization failed on $vm_name"
      return 1
    fi
    if grep -Fq 'DYNATRACE_READY' <<<"$output"; then
      log "[PASS] Dynatrace is ready on $vm_name"
      return 0
    fi
    sleep 15
  done

  log "[FAIL] Timed out waiting for Dynatrace readiness on $vm_name"
  return 1
}

validate_dynatrace_settings
[[ "$LB_TYPE" =~ ^(HTTP|TCP)$ ]] || { log "[FAIL] LB_TYPE must be HTTP or TCP"; exit 1; }
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  log "[FAIL] PORT must be between 1 and 65535"
  exit 1
fi
if [[ "$LB_TYPE" == "HTTP" && ! "$HEALTH_CHECK_PATH" =~ ^/ ]]; then
  log "[FAIL] HEALTH_CHECK_PATH must begin with / for HTTP load balancing"
  exit 1
fi

deploy_stage 1 "Read GitOps desired state"
log "[INFO] Target color=$ACTIVE_COLOR version=$ACTIVE_VERSION image=$ACTIVE_IMAGE"

deploy_stage 2 "Validate the Day-0 health check and backend service"
exists compute health-checks describe "$HEALTH_CHECK" || { log "[FAIL] Run infrastructure/networking/setup-load-balancer.sh before deployment"; exit 1; }
exists compute backend-services describe "$BACKEND" --global || { log "[FAIL] Required backend service $BACKEND does not exist"; exit 1; }

deploy_stage 3 "Create $MIG_SIZE private IIS nodes and unmanaged instance group $TARGET_GROUP"
SERVICE_ACCOUNT_ARGS=(--no-service-account --no-scopes)
STARTUP_ARGS=()
METADATA="app-environment=$(basename "$(dirname "$MANIFEST")"),app-color=${ACTIVE_COLOR},app-version=${ACTIVE_VERSION}"
if [[ "$DYNATRACE_ENABLED" == "true" ]]; then
  SERVICE_ACCOUNT_ARGS=(--service-account="$DYNATRACE_RUNTIME_SERVICE_ACCOUNT" --scopes=cloud-platform)
  NETWORK_ZONE="$DYNATRACE_NETWORK_ZONE"
  [[ "$NETWORK_ZONE" == "disabled" ]] && NETWORK_ZONE=""
  METADATA+=",dynatrace-enabled=true,dynatrace-environment-url=${DYNATRACE_ENVIRONMENT_URL%/},dynatrace-token-secret=${DYNATRACE_TOKEN_SECRET},dynatrace-monitoring-mode=${DYNATRACE_MONITORING_MODE},dynatrace-host-group=${DYNATRACE_HOST_GROUP},dynatrace-network-zone=${NETWORK_ZONE}"
  STARTUP_ARGS=(--metadata-from-file=windows-startup-script-ps1=integrations/dynatrace/install-oneagent.ps1)
fi

if ! exists compute instance-groups unmanaged describe "$TARGET_GROUP" --zone="$ZONE"; then
  gcloud compute instance-groups unmanaged create "$TARGET_GROUP" \
    --project="$PROJECT_ID" --zone="$ZONE" --network="$NETWORK"
fi
for target_vm in "${TARGET_VMS[@]}"; do
  if ! exists compute instances describe "$target_vm" --zone="$ZONE"; then
    gcloud compute instances create "$target_vm" \
      --project="$PROJECT_ID" --zone="$ZONE" \
      --machine-type=e2-standard-2 --image="$ACTIVE_IMAGE" \
      --network="$NETWORK" --subnet="$SUBNET" --no-address \
      --boot-disk-size=200GB --boot-disk-type=pd-balanced \
      --tags="allow-health-check" \
      "${SERVICE_ACCOUNT_ARGS[@]}" \
      --metadata="$METADATA" \
      "${STARTUP_ARGS[@]}"
  fi
  GROUP_INSTANCES="$(gcloud compute instance-groups unmanaged list-instances "$TARGET_GROUP" \
    --project="$PROJECT_ID" --zone="$ZONE" --format='value(instance.basename())' 2>/dev/null || true)"
  if ! grep -Fxq "$target_vm" <<<"$GROUP_INSTANCES"; then
    gcloud compute instance-groups unmanaged add-instances "$TARGET_GROUP" \
      --project="$PROJECT_ID" --zone="$ZONE" --instances="$target_vm"
  fi
done
gcloud compute instance-groups unmanaged set-named-ports "$TARGET_GROUP" \
  --project="$PROJECT_ID" --zone="$ZONE" --named-ports="http:$PORT"

BACKEND_GROUPS="$(gcloud compute backend-services describe "$BACKEND" \
  --project="$PROJECT_ID" --global --format='value(backends.group)')"
if ! grep -Fq "/instanceGroups/$TARGET_GROUP" <<<"$BACKEND_GROUPS"; then
  gcloud compute backend-services add-backend "$BACKEND" \
    --project="$PROJECT_ID" --global \
    --instance-group="$TARGET_GROUP" --instance-group-zone="$ZONE"
fi
sleep 30

if [[ "$DYNATRACE_ENABLED" == "true" ]]; then
  for target_vm in "${TARGET_VMS[@]}"; do
    wait_for_dynatrace "$target_vm"
  done
  log "DYNATRACE_STATUS=READY"
else
  log "DYNATRACE_STATUS=DISABLED"
fi

deploy_stage 4 "Wait for $TARGET_GROUP to pass load-balancer health checks"
deadline=$((SECONDS + 600))
while true; do
  HEALTH="$(gcloud compute backend-services get-health "$BACKEND" \
    --project="$PROJECT_ID" --global --filter="group~/${TARGET_GROUP}$" \
    --format='value(status.healthStatus.healthState)' 2>/dev/null || true)"
  HEALTHY_COUNT="$(grep -cx 'HEALTHY' <<<"$HEALTH" || true)"
  if [[ "$HEALTHY_COUNT" -eq "$MIG_SIZE" ]]; then
    break
  fi
  if (( SECONDS >= deadline )); then
    log "[FAIL] Timed out waiting for a healthy $ACTIVE_COLOR backend"
    exit 1
  fi
  sleep 15
done

deploy_stage 5 "Drain and remove the previous blue/green environment"
mapfile -t OLD_GROUPS < <(
  gcloud compute instance-groups unmanaged list --project="$PROJECT_ID" \
    --filter="name~'^${APP_NAME}-(blue|green)-'" --format='value(name)' 2>/dev/null || true
)
BACKEND_GROUPS="$(gcloud compute backend-services describe "$BACKEND" \
  --project="$PROJECT_ID" --global --format='value(backends.group)')"
for old_group in "${OLD_GROUPS[@]}"; do
  [[ -n "$old_group" && "$old_group" != "$TARGET_GROUP" ]] || continue
  if grep -Fq "/instanceGroups/$old_group" <<<"$BACKEND_GROUPS"; then
    gcloud compute backend-services remove-backend "$BACKEND" \
      --project="$PROJECT_ID" --global \
      --instance-group="$old_group" --instance-group-zone="$ZONE"
  fi
  mapfile -t OLD_VMS < <(
    gcloud compute instance-groups unmanaged list-instances "$old_group" \
      --project="$PROJECT_ID" --zone="$ZONE" --format='value(instance.basename())' 2>/dev/null || true
  )
  gcloud compute instance-groups unmanaged delete "$old_group" \
    --project="$PROJECT_ID" --zone="$ZONE" --quiet
  for old_vm in "${OLD_VMS[@]}"; do
    [[ -n "$old_vm" ]] || continue
    gcloud compute instances delete "$old_vm" --project="$PROJECT_ID" --zone="$ZONE" --quiet
  done
done

deploy_stage 6 "Report the validated load-balancer endpoint"
PUBLIC_IP="$(gcloud compute addresses describe "$ADDRESS" \
  --project="$PROJECT_ID" --global --format='value(address)')"
log "TRAFFIC_COLOR=$ACTIVE_COLOR"
log "APP_VERSION=$ACTIVE_VERSION"
if [[ "$LB_TYPE" == "HTTP" ]]; then
  log "PUBLIC_URL=http://$PUBLIC_IP/"
else
  log "PUBLIC_ENDPOINT=$PUBLIC_IP:$PORT"
fi
log "[PASS] Traffic switched to $ACTIVE_COLOR version $ACTIVE_VERSION"
log "[INFO] Rollback by reverting the deployment manifest commit and merging it"
