#!/usr/bin/env bash
# Reconcile the GitOps deployment manifest into a validated blue/green Compute Engine runtime.
# It creates the active MIG and load balancer resources, shifts traffic, and leaves cleanup to run-demo.sh.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PROJECT_ID="${1:?project id is required}"
ZONE="${2:?zone is required}"
APP_NAME="${3:?application name is required}"
MIG_SIZE="${4:-2}"
DYNATRACE_ENABLED="${5:-false}"
DYNATRACE_ENVIRONMENT_URL="${6:-disabled}"
DYNATRACE_TOKEN_SECRET="${7:-disabled}"
DYNATRACE_RUNTIME_SERVICE_ACCOUNT="${8:-disabled}"
DYNATRACE_MONITORING_MODE="${9:-fullstack}"
DYNATRACE_HOST_GROUP="${10:-gcp-windows-demo}"
DYNATRACE_NETWORK_ZONE="${11:-disabled}"
MANIFEST="environments/prod/deployment.env"
PROJECT_HEALTH_PATH="$(jq -r '.healthPath // "/health.html"' projects/sample/project.json)"
PROJECT_HEALTH_PORT="$(jq -r '.healthPort // 80' projects/sample/project.json)"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

deploy_stage() {
  log "[DEPLOY $1/6] $2"
}

# This file is reviewed in Git before execution and contains assignments only.
# shellcheck disable=SC1090
source "$MANIFEST"

if [[ "${ACTIVE_COLOR:-}" != "blue" && "${ACTIVE_COLOR:-}" != "green" ]]; then
  log "[FAIL] ACTIVE_COLOR must be blue or green"
  exit 1
fi

ACTIVE_IMAGE_VAR="${ACTIVE_COLOR^^}_IMAGE"
ACTIVE_VERSION_VAR="${ACTIVE_COLOR^^}_VERSION"
ACTIVE_IMAGE="${!ACTIVE_IMAGE_VAR:-}"
ACTIVE_VERSION="${!ACTIVE_VERSION_VAR:-}"
[[ -n "$ACTIVE_IMAGE" && -n "$ACTIVE_VERSION" ]] || { log "[FAIL] Active image and version are required"; exit 1; }

if [[ "$ACTIVE_COLOR" == "blue" ]]; then
  INACTIVE_COLOR=green
else
  INACTIVE_COLOR=blue
fi

ACTIVE_MIG="${APP_NAME}-${ACTIVE_COLOR}"
INACTIVE_MIG="${APP_NAME}-${INACTIVE_COLOR}"
HEALTH_CHECK="${APP_NAME}-health"
BACKEND="${APP_NAME}-backend"
URL_MAP="${APP_NAME}-url-map"
PROXY="${APP_NAME}-http-proxy"
ADDRESS="${APP_NAME}-ip"
FORWARDING_RULE="${APP_NAME}-http"
FIREWALL="${APP_NAME}-allow-health-check"
NETWORK_TAG="${APP_NAME}-web"
VERSION_TOKEN="$(printf '%s' "$ACTIVE_VERSION" | tr '[:upper:].+_' '[:lower:]---' | tr -cd 'a-z0-9-')"
IMAGE_TOKEN="$(basename "$ACTIVE_IMAGE" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-' | tail -c 13)"

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
  local mig_name="$1"
  local deadline=$((SECONDS + 600))
  local instances vm output ready_count line key
  declare -A seen=()

  log "[DYNATRACE] Waiting for every VM in $mig_name to report DYNATRACE_READY"
  while (( SECONDS < deadline )); do
    mapfile -t instances < <(
      gcloud compute instance-groups managed list-instances "$mig_name" \
        --project="$PROJECT_ID" --zone="$ZONE" \
        --format='value(instance.basename())' 2>/dev/null || true
    )
    ready_count=0
    for vm in "${instances[@]}"; do
      [[ -n "$vm" ]] || continue
      output="$(gcloud compute instances get-serial-port-output "$vm" \
        --project="$PROJECT_ID" --zone="$ZONE" --port=1 2>/dev/null || true)"

      while IFS= read -r line; do
        [[ "$line" == *DYNATRACE_* ]] || continue
        key="$vm|$line"
        if [[ -z "${seen[$key]:-}" ]]; then
          seen["$key"]=1
          log "[$vm] [DYNATRACE] ${line#*DYNATRACE_}"
        fi
      done <<<"$output"

      if grep -Fq 'DYNATRACE_FAILED:' <<<"$output"; then
        log "[FAIL] Dynatrace initialization failed on $vm"
        return 1
      fi
      if grep -Fq 'DYNATRACE_READY' <<<"$output"; then
        ready_count=$((ready_count + 1))
      fi
    done

    if (( ${#instances[@]} >= MIG_SIZE && ready_count >= MIG_SIZE )); then
      log "[PASS] Dynatrace is ready on $ready_count application VMs"
      return 0
    fi
    sleep 15
  done

  log "[FAIL] Timed out waiting for Dynatrace readiness in $mig_name"
  return 1
}

validate_dynatrace_settings
[[ "$MIG_SIZE" =~ ^[1-9][0-9]*$ ]] || { log "[FAIL] MIG_SIZE must be a positive integer"; exit 1; }

OBSERVABILITY_TOKEN="nodt"
if [[ "$DYNATRACE_ENABLED" == "true" ]]; then
  OBSERVABILITY_TOKEN="dt$(printf '%s' "$DYNATRACE_ENVIRONMENT_URL|$DYNATRACE_MONITORING_MODE|$DYNATRACE_HOST_GROUP|$DYNATRACE_NETWORK_ZONE" | sha256sum | cut -c1-8)"
fi
TEMPLATE="${APP_NAME}-${ACTIVE_COLOR}-${OBSERVABILITY_TOKEN}-${VERSION_TOKEN}-${IMAGE_TOKEN}"
TEMPLATE="$(printf '%s' "$TEMPLATE" | cut -c1-63 | sed 's/-$//')"

deploy_stage 1 "Read GitOps desired state"
log "[INFO] Target color=$ACTIVE_COLOR version=$ACTIVE_VERSION image=$ACTIVE_IMAGE"

deploy_stage 2 "Reconcile firewall, health check and backend service"
if ! exists compute firewall-rules describe "$FIREWALL"; then
  gcloud compute firewall-rules create "$FIREWALL" \
    --project="$PROJECT_ID" \
    --network=default \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:80 \
    --source-ranges=35.191.0.0/16,130.211.0.0/22 \
    --target-tags="$NETWORK_TAG"
fi

if ! exists compute health-checks describe "$HEALTH_CHECK"; then
  gcloud compute health-checks create http "$HEALTH_CHECK" \
    --project="$PROJECT_ID" --port="$PROJECT_HEALTH_PORT" --request-path="$PROJECT_HEALTH_PATH" \
    --check-interval=10s --timeout=5s --healthy-threshold=2 --unhealthy-threshold=3
fi

if ! exists compute backend-services describe "$BACKEND" --global; then
  gcloud compute backend-services create "$BACKEND" \
    --project="$PROJECT_ID" --global --protocol=HTTP --port-name=http \
    --health-checks="$HEALTH_CHECK"
fi

deploy_stage 3 "Create immutable template and reconcile $ACTIVE_MIG"
if ! exists compute instance-templates describe "$TEMPLATE"; then
  SERVICE_ACCOUNT_ARGS=(--no-service-account --no-scopes)
  STARTUP_ARGS=()
  METADATA="app-color=${ACTIVE_COLOR},app-version=${ACTIVE_VERSION}"
  if [[ "$DYNATRACE_ENABLED" == "true" ]]; then
    SERVICE_ACCOUNT_ARGS=(--service-account="$DYNATRACE_RUNTIME_SERVICE_ACCOUNT" --scopes=cloud-platform)
    NETWORK_ZONE="$DYNATRACE_NETWORK_ZONE"
    [[ "$NETWORK_ZONE" == "disabled" ]] && NETWORK_ZONE=""
    METADATA+=",dynatrace-enabled=true,dynatrace-environment-url=${DYNATRACE_ENVIRONMENT_URL%/},dynatrace-token-secret=${DYNATRACE_TOKEN_SECRET},dynatrace-monitoring-mode=${DYNATRACE_MONITORING_MODE},dynatrace-host-group=${DYNATRACE_HOST_GROUP},dynatrace-network-zone=${NETWORK_ZONE}"
    STARTUP_ARGS=(--metadata-from-file=windows-startup-script-ps1=integrations/dynatrace/install-oneagent.ps1)
  fi

  gcloud compute instance-templates create "$TEMPLATE" \
    --project="$PROJECT_ID" \
    --machine-type=e2-standard-2 \
    --image="$ACTIVE_IMAGE" \
    --boot-disk-size=200GB \
    --boot-disk-type=pd-balanced \
    "${SERVICE_ACCOUNT_ARGS[@]}" \
    --tags="$NETWORK_TAG" \
    --metadata="$METADATA" \
    "${STARTUP_ARGS[@]}"
fi

if exists compute instance-groups managed describe "$ACTIVE_MIG" --zone="$ZONE"; then
  gcloud compute instance-groups managed rolling-action start-update "$ACTIVE_MIG" \
    --project="$PROJECT_ID" --zone="$ZONE" \
    --version="template=$TEMPLATE" --max-surge=1 --max-unavailable=0 --replacement-method=substitute
else
  gcloud compute instance-groups managed create "$ACTIVE_MIG" \
    --project="$PROJECT_ID" --zone="$ZONE" --template="$TEMPLATE" --size="$MIG_SIZE"
fi
gcloud compute instance-groups managed set-named-ports "$ACTIVE_MIG" \
  --project="$PROJECT_ID" --zone="$ZONE" --named-ports="http:$PROJECT_HEALTH_PORT"

gcloud compute instance-groups managed wait-until "$ACTIVE_MIG" \
  --project="$PROJECT_ID" --zone="$ZONE" --stable --timeout=900

if [[ "$DYNATRACE_ENABLED" == "true" ]]; then
  wait_for_dynatrace "$ACTIVE_MIG"
  log "DYNATRACE_STATUS=READY"
else
  log "DYNATRACE_STATUS=DISABLED"
fi

BACKEND_GROUPS="$(gcloud compute backend-services describe "$BACKEND" \
  --project="$PROJECT_ID" --global --format='value(backends.group)')"
if ! grep -Fq "/instanceGroups/$ACTIVE_MIG" <<<"$BACKEND_GROUPS"; then
  INITIAL_CAPACITY=0
  [[ -z "$BACKEND_GROUPS" ]] && INITIAL_CAPACITY=1
  gcloud compute backend-services add-backend "$BACKEND" \
    --project="$PROJECT_ID" --global \
    --instance-group="$ACTIVE_MIG" --instance-group-zone="$ZONE" \
    --balancing-mode=UTILIZATION --max-utilization=0.8 --capacity-scaler="$INITIAL_CAPACITY"
fi

deploy_stage 4 "Wait for $ACTIVE_MIG to pass IIS health checks"
deadline=$((SECONDS + 600))
while true; do
  HEALTH="$(gcloud compute backend-services get-health "$BACKEND" \
    --project="$PROJECT_ID" --global --filter="group~/${ACTIVE_MIG}$" \
    --format='value(status.healthStatus.healthState)' 2>/dev/null || true)"
  if grep -q HEALTHY <<<"$HEALTH"; then
    break
  fi
  if (( SECONDS >= deadline )); then
    log "[FAIL] Timed out waiting for a healthy $ACTIVE_COLOR backend"
    exit 1
  fi
  sleep 15
done

deploy_stage 5 "Switch load-balancer capacity to $ACTIVE_COLOR"
gcloud compute backend-services update-backend "$BACKEND" \
  --project="$PROJECT_ID" --global \
  --instance-group="$ACTIVE_MIG" --instance-group-zone="$ZONE" --capacity-scaler=1

BACKEND_GROUPS="$(gcloud compute backend-services describe "$BACKEND" \
  --project="$PROJECT_ID" --global --format='value(backends.group)')"
if grep -Fq "/instanceGroups/$INACTIVE_MIG" <<<"$BACKEND_GROUPS"; then
  gcloud compute backend-services update-backend "$BACKEND" \
    --project="$PROJECT_ID" --global \
    --instance-group="$INACTIVE_MIG" --instance-group-zone="$ZONE" --capacity-scaler=0
fi

# Create the public frontend after the first backend has passed health checks.
deploy_stage 6 "Publish and report the validated HTTP endpoint"
if ! exists compute url-maps describe "$URL_MAP"; then
  gcloud compute url-maps create "$URL_MAP" --project="$PROJECT_ID" --default-service="$BACKEND"
fi
if ! exists compute target-http-proxies describe "$PROXY"; then
  gcloud compute target-http-proxies create "$PROXY" --project="$PROJECT_ID" --url-map="$URL_MAP"
fi
if ! exists compute addresses describe "$ADDRESS" --global; then
  gcloud compute addresses create "$ADDRESS" --project="$PROJECT_ID" --global --ip-version=IPV4
fi
if ! exists compute forwarding-rules describe "$FORWARDING_RULE" --global; then
  gcloud compute forwarding-rules create "$FORWARDING_RULE" \
    --project="$PROJECT_ID" --global --address="$ADDRESS" \
    --target-http-proxy="$PROXY" --ports=80
fi

PUBLIC_IP="$(gcloud compute addresses describe "$ADDRESS" --project="$PROJECT_ID" --global --format='value(address)')"
log "TRAFFIC_COLOR=$ACTIVE_COLOR"
log "APP_VERSION=$ACTIVE_VERSION"
log "PUBLIC_URL=http://$PUBLIC_IP/"
log "[PASS] Traffic switched to $ACTIVE_COLOR version $ACTIVE_VERSION"
log "[INFO] Rollback by reverting the deployment manifest commit and merging it"
