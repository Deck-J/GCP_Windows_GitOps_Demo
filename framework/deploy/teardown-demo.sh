#!/usr/bin/env bash
# Delete temporary blue/green unmanaged groups and VMs without removing Day-0 load-balancer resources.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit

# shellcheck disable=SC1091
source environments/prod/deployment.env

PROJECT_ID="${1:?project id is required}"
ZONE="${2:?zone is required}"
APP_NAME="${3:?application name is required}"
NETWORK="${NETWORK:-default}"
SUBNET="${SUBNET:-default}"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

if ! [[ "$APP_NAME" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]] || (( ${#APP_NAME} > 32 )); then
  log "[FAIL] APP_NAME must be a lowercase GCP-safe name of at most 32 characters"
  exit 2
fi

BACKEND="windows-app-backend"
FAILED=0

exists() {
  gcloud "$@" --project="$PROJECT_ID" >/dev/null 2>&1
}

log "[TEARDOWN 1/2] Drain temporary $APP_NAME blue/green backends"
mapfile -t GROUPS < <(
  gcloud compute instance-groups unmanaged list --project="$PROJECT_ID" \
    --filter="name~'^${APP_NAME}-(blue|green)-'" --format='value(name)' 2>/dev/null || true
)
BACKEND_GROUPS="$(gcloud compute backend-services describe "$BACKEND" \
  --project="$PROJECT_ID" --global --format='value(backends.group)' 2>/dev/null || true)"

for group in "${GROUPS[@]}"; do
  [[ -n "$group" ]] || continue
  if grep -Fq "/instanceGroups/$group" <<<"$BACKEND_GROUPS"; then
    log "[DRAIN] Removing $group from $BACKEND"
    if ! gcloud compute backend-services remove-backend "$BACKEND" \
      --project="$PROJECT_ID" --global \
      --instance-group="$group" --instance-group-zone="$ZONE"; then
      log "[FAIL] Could not detach $group; leaving its group and VMs intact"
      FAILED=1
      continue
    fi
  fi

  mapfile -t VMS < <(
    gcloud compute instance-groups unmanaged list-instances "$group" \
      --project="$PROJECT_ID" --zone="$ZONE" --format='value(instance.basename())' 2>/dev/null || true
  )
  log "[DELETE] Unmanaged instance group $group"
  if ! gcloud compute instance-groups unmanaged delete "$group" \
    --project="$PROJECT_ID" --zone="$ZONE" --quiet; then
    log "[FAIL] Could not delete group $group; leaving its VMs intact"
    FAILED=1
    continue
  fi
  for vm in "${VMS[@]}"; do
    [[ -n "$vm" ]] || continue
    log "[DELETE] Private VM $vm"
    if ! gcloud compute instances delete "$vm" \
      --project="$PROJECT_ID" --zone="$ZONE" --quiet; then
      log "[FAIL] Could not delete VM $vm"
      FAILED=1
    fi
  done
done

log "[TEARDOWN 2/2] Preserve Day-0 load-balancer, health-check and firewall resources"

if [[ "$FAILED" -ne 0 ]]; then
  log "[FAIL] Runtime teardown finished with errors"
  exit 1
fi

log "[PASS] Runtime teardown complete"
