#!/usr/bin/env bash
# Verify that temporary blue/green runtime resources are gone after demo teardown.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit

PROJECT_ID="${1:?project id is required}"
ZONE="${2:?zone is required}"
APP_NAME="${3:?application name is required}"
MANAGEMENT_STATION_ENABLED="${4:-false}"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

if ! [[ "$APP_NAME" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]] || (( ${#APP_NAME} > 32 )); then
  log "[FAIL] APP_NAME must be a lowercase GCP-safe name of at most 32 characters"
  exit 2
fi
[[ "$MANAGEMENT_STATION_ENABLED" =~ ^(true|false)$ ]] || {
  log "[FAIL] MANAGEMENT_STATION_ENABLED must be true or false"
  exit 2
}

FAILED=0
MANAGEMENT_VM="${APP_NAME}-management"
MANAGEMENT_IAP_FIREWALL="${APP_NAME}-management-iap-rdp"
WORKER_RDP_FIREWALL="${APP_NAME}-workers-management-rdp"

log "[VERIFY] Checking for leftover $APP_NAME blue/green groups"
mapfile -t GROUPS < <(
  gcloud compute instance-groups unmanaged list --project="$PROJECT_ID" \
    --filter="name~'^${APP_NAME}-(blue|green)-'" --format='value(name)' 2>/dev/null || true
)
if (( ${#GROUPS[@]} > 0 )); then
  printf '%s\n' "${GROUPS[@]}" | sed 's/^/[LEFTOVER] group /'
  FAILED=1
else
  log "[PASS] No temporary blue/green groups remain"
fi

log "[VERIFY] Checking for leftover $APP_NAME blue/green VMs"
mapfile -t VMS < <(
  gcloud compute instances list --project="$PROJECT_ID" \
    --zones="$ZONE" --filter="name~'^${APP_NAME}-(blue|green)-'" \
    --format='value(name)' 2>/dev/null || true
)
if (( ${#VMS[@]} > 0 )); then
  printf '%s\n' "${VMS[@]}" | sed 's/^/[LEFTOVER] vm /'
  FAILED=1
else
  log "[PASS] No temporary blue/green VMs remain"
fi

if [[ "$MANAGEMENT_STATION_ENABLED" == "true" ]]; then
  log "[VERIFY] Management station is enabled; preserving $MANAGEMENT_VM and RDP firewall rules by policy"
else
  log "[VERIFY] Checking that disabled management resources are absent"
  if gcloud compute instances describe "$MANAGEMENT_VM" \
    --project="$PROJECT_ID" --zone="$ZONE" >/dev/null 2>&1; then
    log "[LEFTOVER] vm $MANAGEMENT_VM"
    FAILED=1
  else
    log "[PASS] No management station remains"
  fi

  for rule in "$MANAGEMENT_IAP_FIREWALL" "$WORKER_RDP_FIREWALL"; do
    if gcloud compute firewall-rules describe "$rule" \
      --project="$PROJECT_ID" >/dev/null 2>&1; then
      log "[LEFTOVER] firewall $rule"
      FAILED=1
    else
      log "[PASS] Firewall rule $rule is absent"
    fi
  done
fi

if [[ "$FAILED" -ne 0 ]]; then
  log "[FAIL] Cleanup verification found leftover runtime resources"
  exit 1
fi

log "[PASS] Cleanup verification complete"
