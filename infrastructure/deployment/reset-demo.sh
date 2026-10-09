#!/usr/bin/env bash
# Guarded cleanup for demo-only GCP resources. Plans by default; deletes only with --apply.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit

APPLY=false
ENVIRONMENT="all"
ZONE="${GCP_ZONE:-us-central1-a}"
PROJECT_ID="${GCP_PROJECT_ID:-}"
DELETE_IMAGES=false

usage() {
  cat <<'USAGE'
Usage: infrastructure/deployment/reset-demo.sh --project PROJECT_ID [options]

Options:
  --environment dev|prod|all  Environment to clean (default: all)
  --zone ZONE                 GCP zone (default: GCP_ZONE or us-central1-a)
  --delete-images             Also delete windows-github-runner-* images
  --apply                     Actually delete resources. Without this, only prints the plan.
  -h, --help                  Show this help.

The script targets demo resources created by this repository's naming
conventions. It preserves environment load-balancer frontends by default.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_ID="${2:-}"; shift 2 ;;
    --project=*)
      PROJECT_ID="${1#*=}"; shift ;;
    --environment)
      ENVIRONMENT="${2:-}"; shift 2 ;;
    --environment=*)
      ENVIRONMENT="${1#*=}"; shift ;;
    --zone)
      ZONE="${2:-}"; shift 2 ;;
    --zone=*)
      ZONE="${1#*=}"; shift ;;
    --delete-images)
      DELETE_IMAGES=true; shift ;;
    --apply)
      APPLY=true; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "[FAIL] Unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

run_or_plan() {
  if [[ "$APPLY" == "true" ]]; then
    log "[APPLY] $*"
    "$@"
  else
    printf '[PLAN] %q' "$1"
    shift
    printf ' %q' "$@"
    printf '\n'
  fi
}

app_names_for_environment() {
  case "$ENVIRONMENT" in
    dev) printf '%s\n' dev-iis-demo ;;
    prod) printf '%s\n' prod-iis-demo ;;
    all) printf '%s\n%s\n' dev-iis-demo prod-iis-demo ;;
    *) echo "[FAIL] --environment must be dev, prod, or all" >&2; exit 2 ;;
  esac
}

[[ -n "$PROJECT_ID" ]] || { echo "[FAIL] --project PROJECT_ID is required" >&2; exit 2; }
command -v gcloud >/dev/null 2>&1 || { echo "[FAIL] gcloud is required" >&2; exit 1; }
gcloud projects describe "$PROJECT_ID" --format='value(projectId)' >/dev/null || exit 1

if [[ "$APPLY" != "true" ]]; then
  log "[INFO] Dry run only. Re-run with --apply to delete planned resources."
fi

mapfile -t APP_NAMES < <(app_names_for_environment)

log "[RESET 1/5] Temporary blue/green runtime resources"
for app_name in "${APP_NAMES[@]}"; do
  if [[ "$APPLY" == "true" ]]; then
    bash infrastructure/deployment/teardown-demo.sh "$PROJECT_ID" "$ZONE" "$app_name"
  else
    log "[PLAN] Would run teardown-demo for $app_name"
    gcloud compute instance-groups unmanaged list --project="$PROJECT_ID" \
      --filter="name~'^${app_name}-(blue|green)-'" \
      --format='table(name,zone.basename())' 2>/dev/null || true
  fi
done

log "[RESET 2/5] Management stations"
for app_name in "${APP_NAMES[@]}"; do
  vm="${app_name}-management"
  if gcloud compute instances describe "$vm" --project="$PROJECT_ID" --zone="$ZONE" >/dev/null 2>&1; then
    run_or_plan gcloud compute instances delete "$vm" --project="$PROJECT_ID" --zone="$ZONE" --quiet
  fi
done

log "[RESET 3/5] Image-build temporary VMs and firewall rules"
mapfile -t TEMP_VMS < <(
  gcloud compute instances list --project="$PROJECT_ID" \
    --filter="zone:($ZONE) AND (name~'^win-image-' OR name~'^win-test-')" \
    --format='value(name)' 2>/dev/null || true
)
for vm in "${TEMP_VMS[@]}"; do
  [[ -n "$vm" ]] || continue
  run_or_plan gcloud compute instances delete "$vm" --project="$PROJECT_ID" --zone="$ZONE" --quiet
done
mapfile -t TEMP_RULES < <(
  gcloud compute firewall-rules list --project="$PROJECT_ID" \
    --filter="name~'^win-image-.*-iap-(ssh|rdp)$'" \
    --format='value(name)' 2>/dev/null || true
)
for rule in "${TEMP_RULES[@]}"; do
  [[ -n "$rule" ]] || continue
  run_or_plan gcloud compute firewall-rules delete "$rule" --project="$PROJECT_ID" --quiet
done

log "[RESET 4/5] Optional generated images"
if [[ "$DELETE_IMAGES" == "true" ]]; then
  mapfile -t IMAGES < <(
    gcloud compute images list --project="$PROJECT_ID" \
      --filter="name~'^windows-github-runner-'" --format='value(name)' 2>/dev/null || true
  )
  for image in "${IMAGES[@]}"; do
    [[ -n "$image" ]] || continue
    run_or_plan gcloud compute images delete "$image" --project="$PROJECT_ID" --quiet
  done
else
  log "[SKIP] Image deletion disabled; pass --delete-images to include generated images"
fi

log "[RESET 5/5] Done"
if [[ "$APPLY" != "true" ]]; then
  log "[PASS] Reset plan complete; no resources were deleted"
else
  log "[PASS] Reset apply complete"
fi
