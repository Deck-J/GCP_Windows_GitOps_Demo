#!/usr/bin/env bash
# Provision the persistent global load-balancer frontend and backend for one environment.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PROJECT_ID="${1:-${PROJECT_ID:-}}"
ZONE="${2:-${ZONE:-}}"
APP_NAME="${3:-prod-iis-demo}"
MANIFEST="${4:-environments/prod/deployment.env}"
[[ -f "$MANIFEST" ]] || { printf '[FAIL] Deployment manifest does not exist: %s\n' "$MANIFEST" >&2; exit 2; }
# This file is reviewed in Git before execution and contains assignments only.
# shellcheck disable=SC1090
source "$MANIFEST"
NETWORK="${NETWORK:-default}"
SUBNET="${SUBNET:-default}"
LB_TYPE="${LB_TYPE:-HTTP}"
HEALTH_CHECK_PATH="${HEALTH_CHECK_PATH:-/health.html}"
PORT="${PORT:-80}"

# Validate manifest-derived values before creating any persistent frontend
# resources; malformed ports or protocols otherwise fail partway through setup.
[[ -n "$PROJECT_ID" ]] || { printf '[FAIL] PROJECT_ID is required (argument or environment)\n' >&2; exit 2; }
[[ "$LB_TYPE" =~ ^(HTTP|TCP)$ ]] || { printf '[FAIL] LB_TYPE must be HTTP or TCP\n' >&2; exit 2; }
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
  printf '[FAIL] PORT must be between 1 and 65535\n' >&2
  exit 2
fi
if [[ "$LB_TYPE" == "HTTP" && ! "$HEALTH_CHECK_PATH" =~ ^/ ]]; then
  printf '[FAIL] HEALTH_CHECK_PATH must begin with / for HTTP load balancing\n' >&2
  exit 2
fi

if ! [[ "$APP_NAME" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ ]] || (( ${#APP_NAME} > 32 )); then
  printf '[FAIL] APP_NAME must be a lowercase GCP-safe name of at most 32 characters\n' >&2
  exit 2
fi

HEALTH_CHECK="${APP_NAME}-health"
BACKEND="${APP_NAME}-backend"
URL_MAP="${APP_NAME}-url-map"
HTTP_PROXY="${APP_NAME}-http-proxy"
TCP_PROXY="${APP_NAME}-tcp-proxy"
ADDRESS="${APP_NAME}-ip"
FORWARDING_RULE="${APP_NAME}-forwarding-rule"
FIREWALL="${APP_NAME}-allow-health-check"

exists() {
  gcloud "$@" --project="$PROJECT_ID" >/dev/null 2>&1
}

# Provisioning is idempotent: each named resource is created only if absent,
# leaving the global frontend intact across repeated environment deployments.
# Names include the environment's app name so Dev and Prod can keep independent
# frontends and backends while sharing the repository's provisioning logic.
printf '[INFO] Provisioning %s load balancer in project %s (zone=%s network=%s subnet=%s)\n' \
  "$LB_TYPE" "$PROJECT_ID" "${ZONE:-unspecified}" "$NETWORK" "$SUBNET"

# Only Google health-check probe ranges may reach the application port through
# this rule. Each environment gets its own target tag and rule for isolation.
if ! exists compute firewall-rules describe "$FIREWALL"; then
  gcloud compute firewall-rules create "$FIREWALL" \
    --project="$PROJECT_ID" --network="$NETWORK" \
    --direction=INGRESS --action=ALLOW --rules="tcp:$PORT" \
    --source-ranges=35.191.0.0/16,130.211.0.0/22 \
    --target-tags=allow-health-check
fi

# The probe protocol/path must agree with the backend service configured below.
if ! exists compute health-checks describe "$HEALTH_CHECK"; then
  # HTTP uses URL map -> HTTP proxy; TCP uses a TCP proxy directly. The public
  # address and forwarding rule are created once and reused across demo runs.
  if [[ "$LB_TYPE" == "HTTP" ]]; then
    gcloud compute health-checks create http "$HEALTH_CHECK" \
      --project="$PROJECT_ID" --port="$PORT" --request-path="$HEALTH_CHECK_PATH" \
      --check-interval=10s --timeout=5s --healthy-threshold=2 --unhealthy-threshold=3
  else
    gcloud compute health-checks create tcp "$HEALTH_CHECK" \
      --project="$PROJECT_ID" --port="$PORT" \
      --check-interval=10s --timeout=5s --healthy-threshold=2 --unhealthy-threshold=3
  fi
fi

if ! exists compute backend-services describe "$BACKEND" --global; then
  if [[ "$LB_TYPE" == "HTTP" ]]; then
    gcloud compute backend-services create "$BACKEND" \
      --project="$PROJECT_ID" --global --load-balancing-scheme=EXTERNAL_MANAGED \
      --protocol=HTTP --port-name=http --health-checks="$HEALTH_CHECK"
  else
    gcloud compute backend-services create "$BACKEND" \
      --project="$PROJECT_ID" --global --load-balancing-scheme=EXTERNAL_MANAGED \
      --protocol=TCP --health-checks="$HEALTH_CHECK"
  fi
fi

if ! exists compute addresses describe "$ADDRESS" --global; then
  gcloud compute addresses create "$ADDRESS" \
    --project="$PROJECT_ID" --global --ip-version=IPV4
fi

if [[ "$LB_TYPE" == "HTTP" ]]; then
  if ! exists compute url-maps describe "$URL_MAP"; then
    gcloud compute url-maps create "$URL_MAP" \
      --project="$PROJECT_ID" --default-service="$BACKEND"
  fi
  if ! exists compute target-http-proxies describe "$HTTP_PROXY"; then
    gcloud compute target-http-proxies create "$HTTP_PROXY" \
      --project="$PROJECT_ID" --url-map="$URL_MAP"
  fi
  if ! exists compute forwarding-rules describe "$FORWARDING_RULE" --global; then
    gcloud compute forwarding-rules create "$FORWARDING_RULE" \
      --project="$PROJECT_ID" --global --load-balancing-scheme=EXTERNAL_MANAGED \
      --address="$ADDRESS" --target-http-proxy="$HTTP_PROXY" --ports="$PORT"
  fi
elif [[ "$LB_TYPE" == "TCP" ]]; then
  if ! exists compute target-tcp-proxies describe "$TCP_PROXY"; then
    gcloud compute target-tcp-proxies create "$TCP_PROXY" \
      --project="$PROJECT_ID" --global --backend-service="$BACKEND" --proxy-header=NONE
  fi
  if ! exists compute forwarding-rules describe "$FORWARDING_RULE" --global; then
    gcloud compute forwarding-rules create "$FORWARDING_RULE" \
      --project="$PROJECT_ID" --global --load-balancing-scheme=EXTERNAL_MANAGED \
      --address="$ADDRESS" --target-tcp-proxy="$TCP_PROXY" --ports="$PORT"
  fi
fi

PUBLIC_IP="$(gcloud compute addresses describe "$ADDRESS" \
  --project="$PROJECT_ID" --global --format='value(address)')"
printf '[PASS] %s load balancer %s is ready at %s:%s\n' "$LB_TYPE" "$APP_NAME" "$PUBLIC_IP" "$PORT"