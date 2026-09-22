#!/usr/bin/env bash
# Delete the temporary blue/green demo MIGs, instance templates, load balancer, health check,
# firewall rule, and reserved address without touching reusable images or secrets.
set -uo pipefail

PROJECT_ID="${1:?project id is required}"
ZONE="${2:?zone is required}"
APP_NAME="${3:?application name is required}"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

if ! [[ "$APP_NAME" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]] || (( ${#APP_NAME} > 32 )); then
  log "[FAIL] APP_NAME must be a lowercase GCP-safe name of at most 32 characters"
  exit 2
fi

BLUE_MIG="${APP_NAME}-blue"
GREEN_MIG="${APP_NAME}-green"
HEALTH_CHECK="${APP_NAME}-health"
BACKEND="${APP_NAME}-backend"
URL_MAP="${APP_NAME}-url-map"
PROXY="${APP_NAME}-http-proxy"
ADDRESS="${APP_NAME}-ip"
FORWARDING_RULE="${APP_NAME}-http"
FIREWALL="${APP_NAME}-allow-health-check"
FAILED=0

exists() {
  gcloud "$@" --project="$PROJECT_ID" >/dev/null 2>&1
}

delete_if_present() {
  local description="$1"
  shift
  local describe_args=()
  local delete_args=()
  local parsing_delete=false

  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then
      parsing_delete=true
    elif [[ "$parsing_delete" == "true" ]]; then
      delete_args+=("$1")
    else
      describe_args+=("$1")
    fi
    shift
  done

  if exists "${describe_args[@]}"; then
    log "[DELETE] $description"
    if ! gcloud "${delete_args[@]}" --project="$PROJECT_ID" --quiet; then
      log "[FAIL] Could not delete $description"
      FAILED=1
    fi
  else
    log "[SKIP] Already absent: $description"
  fi
}

log "[TEARDOWN 1/4] Remove public frontend and backend references for $APP_NAME"

# Delete references before the resources that they reference.
delete_if_present "global forwarding rule $FORWARDING_RULE" \
  compute forwarding-rules describe "$FORWARDING_RULE" --global -- \
  compute forwarding-rules delete "$FORWARDING_RULE" --global
delete_if_present "target HTTP proxy $PROXY" \
  compute target-http-proxies describe "$PROXY" -- \
  compute target-http-proxies delete "$PROXY"
delete_if_present "URL map $URL_MAP" \
  compute url-maps describe "$URL_MAP" -- \
  compute url-maps delete "$URL_MAP"
delete_if_present "backend service $BACKEND" \
  compute backend-services describe "$BACKEND" --global -- \
  compute backend-services delete "$BACKEND" --global

log "[TEARDOWN 2/4] Remove blue and green managed instance groups and disks"
delete_if_present "blue managed instance group $BLUE_MIG" \
  compute instance-groups managed describe "$BLUE_MIG" --zone="$ZONE" -- \
  compute instance-groups managed delete "$BLUE_MIG" --zone="$ZONE"
delete_if_present "green managed instance group $GREEN_MIG" \
  compute instance-groups managed describe "$GREEN_MIG" --zone="$ZONE" -- \
  compute instance-groups managed delete "$GREEN_MIG" --zone="$ZONE"

# Templates have immutable version suffixes. Only names created by this demo
# are selected; unrelated project templates are never included.
log "[TEARDOWN 3/4] Remove versioned demo instance templates"
mapfile -t TEMPLATES < <(
  gcloud compute instance-templates list \
    --project="$PROJECT_ID" \
    --filter="name~'^${APP_NAME}-(blue|green)-'" \
    --format='value(name)' 2>/dev/null || true
)
for template in "${TEMPLATES[@]}"; do
  [[ -z "$template" ]] && continue
  log "[DELETE] instance template $template"
  if ! gcloud compute instance-templates delete "$template" \
    --project="$PROJECT_ID" --quiet; then
    log "[FAIL] Could not delete instance template $template"
    FAILED=1
  fi
done

log "[TEARDOWN 4/4] Remove health check, firewall rule and reserved address"
delete_if_present "health check $HEALTH_CHECK" \
  compute health-checks describe "$HEALTH_CHECK" -- \
  compute health-checks delete "$HEALTH_CHECK"
delete_if_present "health-check firewall rule $FIREWALL" \
  compute firewall-rules describe "$FIREWALL" -- \
  compute firewall-rules delete "$FIREWALL"
delete_if_present "global address $ADDRESS" \
  compute addresses describe "$ADDRESS" --global -- \
  compute addresses delete "$ADDRESS" --global

if [[ "$FAILED" -ne 0 ]]; then
  log "[FAIL] Runtime teardown finished with errors"
  exit 1
fi

log "[PASS] Runtime teardown complete"
