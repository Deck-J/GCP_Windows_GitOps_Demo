#!/usr/bin/env bash
# Build an immutable Windows image: create a builder VM, stream provisioning, capture the disk,
# smoke-test the image, and remove temporary resources on success or failure.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

POSITIONAL_ARGS=()
MANAGEMENT_MODE="${MANAGEMENT_MODE:-false}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --management-mode)
      MANAGEMENT_MODE="true"
      if [[ "${2:-}" == "true" || "${2:-}" == "false" ]]; then
        MANAGEMENT_MODE="$2"
        shift
      fi
      ;;
    --management-mode=*)
      MANAGEMENT_MODE="${1#*=}"
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      ;;
  esac
  shift
done
set -- "${POSITIONAL_ARGS[@]}"

[[ "$MANAGEMENT_MODE" =~ ^(true|false)$ ]] || { printf '[FAIL] --management-mode must be true or false\n' >&2; exit 2; }

PROJECT_ID="${1:?project id is required}"
ZONE="${2:?zone is required}"
SOURCE_IMAGE_FAMILY="${3:?source image family is required}"
IMAGE_FAMILY="${4:?destination image family is required}"
BUILD_ID_RAW="${5:?Cloud Build id is required}"
RUNNER_VERSION="${6:?runner version is required}"
VS_INSTALL_MODE="${7:-web-community}"
KEEP_FAILED_VM="${8:-false}"
APP_VERSION="${9:?application version is required}"
SOURCE_REVISION="${10:?source revision is required}"
VS_EDITION="${11:-enterprise}"
VS_MEDIA_URI="${12:-}"
VS_PRODUCT_KEY_SECRET="${13:-}"
BUILDER_SERVICE_ACCOUNT="${14:-}"
ARTIFACT_GCS_URI="${15:-disabled}"
NETWORK="${NETWORK:-default}"
SUBNET="${SUBNET:-default}"

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

pipeline_stage() {
  log "[PIPELINE $1/6] $2"
}

on_error() {
  local exit_code=$?
  log "[FAIL] Image pipeline stopped at line $1 with exit code $exit_code"
}
trap 'on_error "$LINENO"' ERR

PROJECT_MODE="$(jq -r '.mode // "sample"' applications/sample/project.json)"
PROJECT_VERSION_FILE="$(jq -r '.versionFile // "applications/sample/VERSION"' applications/sample/project.json)"
REPO_APP_VERSION="$(tr -d '[:space:]' < "$PROJECT_VERSION_FILE")"
if [[ "$APP_VERSION" != "$REPO_APP_VERSION" ]]; then
  log "[FAIL] APP_VERSION $APP_VERSION does not match the configured version file $PROJECT_VERSION_FILE ($REPO_APP_VERSION)"
  exit 1
fi

# Build deterministic resource names from the Cloud Build ID, app version,
# and source revision so concurrent or repeated builds do not collide.
BUILD_TOKEN="$(printf '%s' "$BUILD_ID_RAW" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-18)"
BUILD_VM="win-image-${BUILD_TOKEN}"
TEST_VM="win-test-${BUILD_TOKEN}"
VERSION_TOKEN="$(printf '%s' "$APP_VERSION" | tr '[:upper:].+_' '[:lower:]---' | tr -cd 'a-z0-9-')"
REVISION_TOKEN="$(printf '%s' "$SOURCE_REVISION" | tr '[:upper:]_' '[:lower:]-' | tr -cd 'a-z0-9-' | cut -c1-12)"
[[ -z "$REVISION_TOKEN" ]] && REVISION_TOKEN="$BUILD_TOKEN"
IMAGE_NAME="${IMAGE_FAMILY}-${VERSION_TOKEN}-${REVISION_TOKEN}"
IMAGE_NAME="$(printf '%s' "$IMAGE_NAME" | cut -c1-63 | sed 's/-$//')"
SSH_TAG="${BUILD_VM}-ssh"
SSH_FIREWALL="${BUILD_VM}-iap-ssh"
RDP_TAG="${BUILD_VM}-iap-rdp"
RDP_FIREWALL="${BUILD_VM}-iap-rdp"
VS_CONFIG_B64=''
if [[ -f applications/sample/config/vs2022.vsconfig ]]; then
  VS_CONFIG_B64="$(base64 -w0 applications/sample/config/vs2022.vsconfig)"
fi
APP_INDEX_B64=''
APP_HEALTH_B64=''
DEMO_PROJECT_B64=''
DEMO_PROGRAM_B64=''
DEMO_GLOBAL_JSON_B64=''
if [[ "$PROJECT_MODE" == "sample" ]]; then
  APP_INDEX_B64="$(base64 -w0 applications/sample/src/index.html)"
  APP_HEALTH_B64="$(base64 -w0 applications/sample/src/health.html)"
  DEMO_PROJECT_B64="$(base64 -w0 applications/sample/demo/SevenDemo/SevenDemo.csproj)"
  DEMO_PROGRAM_B64="$(base64 -w0 applications/sample/demo/SevenDemo/Program.cs)"
  DEMO_GLOBAL_JSON_B64="$(base64 -w0 applications/sample/demo/SevenDemo/global.json)"
fi
PROJECT_SETUP_B64="$(base64 -w0 "$(jq -r '.setupScript' applications/sample/project.json)")"
PROJECT_VALIDATE_B64="$(base64 -w0 "$(jq -r '.validateScript' applications/sample/project.json)")"
PROJECT_HEALTH_PATH="$(jq -r '.healthPath // "/health.html"' applications/sample/project.json)"
PROJECT_HEALTH_PORT="$(jq -r '.healthPort // 80' applications/sample/project.json)"
BUILD_TIMEOUT_SECONDS=6300
TEST_TIMEOUT_SECONDS=900
POLL_SECONDS=20
BUILD_SUCCEEDED=false
MANAGEMENT_VM_CREATED=false
SSH_USER='gcebuilder'
SSH_KEY_DIR=''
SSH_KEY_FILE=''
ARTIFACT_TEMP_DIR=''
ARTIFACT_LOCAL_PATH=''
declare -A SERIAL_LINES_SEEN=()

cleanup() {
  local exit_code=$?
  set +e

  # Keep an explicitly requested management VM, otherwise remove only resources
  # created for this unique build and discard its ephemeral SSH private key.
  if [[ "$MANAGEMENT_MODE" == "true" && "$MANAGEMENT_VM_CREATED" == "true" ]]; then
    log "[CLEANUP] Preserving management VM $BUILD_VM and its IAP RDP firewall rule"
  elif [[ "$exit_code" -ne 0 && "$KEEP_FAILED_VM" == "true" ]]; then
    log "[CLEANUP] Build failed; preserving temporary VMs because KEEP_FAILED_VM=true"
  else
    log "[CLEANUP] Removing temporary smoke-test and builder VMs"
    gcloud compute instances delete "$TEST_VM" \
      --project="$PROJECT_ID" --zone="$ZONE" --quiet >/dev/null 2>&1 || true
    gcloud compute instances delete "$BUILD_VM" \
      --project="$PROJECT_ID" --zone="$ZONE" --quiet >/dev/null 2>&1 || true
  fi

  if [[ "$MANAGEMENT_MODE" != "true" && "$exit_code" -ne 0 && "$BUILD_SUCCEEDED" != "true" ]]; then
    log "[CLEANUP] Removing failed candidate image if it exists"
    gcloud compute images delete "$IMAGE_NAME" \
      --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  fi

  gcloud compute firewall-rules delete "$SSH_FIREWALL" \
    --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  if [[ "$MANAGEMENT_VM_CREATED" != "true" ]]; then
    gcloud compute firewall-rules delete "$RDP_FIREWALL" \
      --project="$PROJECT_ID" --quiet >/dev/null 2>&1 || true
  fi

  if [[ -n "$SSH_KEY_DIR" ]]; then
    rm -rf "$SSH_KEY_DIR"
  fi
  if [[ -n "$ARTIFACT_TEMP_DIR" ]]; then
    rm -rf "$ARTIFACT_TEMP_DIR"
  fi

  exit "$exit_code"
}
trap cleanup EXIT

serial_output() {
  gcloud compute instances get-serial-port-output "$1" \
    --project="$PROJECT_ID" --zone="$ZONE" --port=1 2>/dev/null || true
}

# Serial output is the status channel for Windows startup and Sysprep, since the
# private builder has neither a public IP nor a persistent SSH server.
emit_serial_progress() {
  local vm_name="$1"
  local output="$2"
  local line payload number total label message key

  while IFS= read -r line; do
    if [[ "$line" == *"DEMO_STAGE|"* ]]; then
      payload="${line#*DEMO_STAGE|}"
      IFS='|' read -r number total message <<<"$payload"
      key="$vm_name|stage|$number|$message"
      if [[ -z "${SERIAL_LINES_SEEN[$key]:-}" ]]; then
        SERIAL_LINES_SEEN[$key]=1
        log "[$vm_name] [STAGE $number/$total] $message"
      fi
    elif [[ "$line" == *"DEMO_PASS|"* ]]; then
      payload="${line#*DEMO_PASS|}"
      IFS='|' read -r label message <<<"$payload"
      key="$vm_name|pass|$label|$message"
      if [[ -z "${SERIAL_LINES_SEEN[$key]:-}" ]]; then
        SERIAL_LINES_SEEN[$key]=1
        log "[$vm_name] [PASS] $label - $message"
      fi
    elif [[ "$line" == *"DEMO_INFO|"* ]]; then
      message="${line#*DEMO_INFO|}"
      key="$vm_name|info|$message"
      if [[ -z "${SERIAL_LINES_SEEN[$key]:-}" ]]; then
        SERIAL_LINES_SEEN[$key]=1
        log "[$vm_name] [INFO] $message"
      fi
    fi
  done <<<"$output"
}

wait_for_marker() {
  local vm_name="$1"
  local success_marker="$2"
  local failure_marker="$3"
  local timeout_seconds="$4"
  local started_at now output status
  started_at="$(date +%s)"

  while true; do
    output="$(serial_output "$vm_name")"
    emit_serial_progress "$vm_name" "$output"

    if grep -Fq "$success_marker" <<<"$output"; then
      log "[$vm_name] [PASS] Reported $success_marker"
      return 0
    fi

    if grep -Fq "$failure_marker" <<<"$output"; then
      log "[$vm_name] [FAIL] Reported a failure"
      log "$(grep -F "$failure_marker" <<<"$output" | tail -1 || true)"
      return 1
    fi

    status="$(gcloud compute instances describe "$vm_name" \
      --project="$PROJECT_ID" --zone="$ZONE" --format='value(status)' 2>/dev/null || true)"
    if [[ "$status" == "TERMINATED" ]]; then
      log "[$vm_name] [FAIL] Stopped before reporting $success_marker"
      return 1
    fi

    now="$(date +%s)"
    if (( now - started_at >= timeout_seconds )); then
      log "[$vm_name] [FAIL] Timed out waiting for $success_marker"
      return 1
    fi

    sleep "$POLL_SECONDS"
  done
}

wait_for_terminated() {
  local vm_name="$1"
  local timeout_seconds="$2"
  local started_at now status
  started_at="$(date +%s)"

  while true; do
    status="$(gcloud compute instances describe "$vm_name" \
      --project="$PROJECT_ID" --zone="$ZONE" --format='value(status)' 2>/dev/null || true)"
    [[ "$status" == "TERMINATED" ]] && return 0

    now="$(date +%s)"
    if (( now - started_at >= timeout_seconds )); then
      log "[$vm_name] [FAIL] Timed out while waiting for shutdown"
      return 1
    fi
    sleep "$POLL_SECONDS"
  done
}

ssh_command() {
  local vm_name="$1"
  local command="$2"
  gcloud compute ssh "$SSH_USER@$vm_name" \
    --project="$PROJECT_ID" --zone="$ZONE" \
    --tunnel-through-iap --quiet --ssh-key-file="$SSH_KEY_FILE" \
    --ssh-flag='-o UserKnownHostsFile=/dev/null' \
    --ssh-flag='-o StrictHostKeyChecking=no' \
    --command="$command"
}

copy_to_vm() {
  local vm_name="$1"
  local source_path="$2"
  local destination_path="$3"
  gcloud compute scp "$source_path" "$SSH_USER@$vm_name:$destination_path" \
    --project="$PROJECT_ID" --zone="$ZONE" \
    --tunnel-through-iap --quiet --ssh-key-file="$SSH_KEY_FILE" \
    --scp-flag='-o UserKnownHostsFile=/dev/null' \
    --scp-flag='-o StrictHostKeyChecking=no'
}

copy_from_vm() {
  local vm_name="$1"
  local source_path="$2"
  local destination_path="$3"
  gcloud compute scp "$SSH_USER@$vm_name:$source_path" "$destination_path" \
    --project="$PROJECT_ID" --zone="$ZONE" \
    --tunnel-through-iap --quiet --ssh-key-file="$SSH_KEY_FILE" \
    --scp-flag='-o UserKnownHostsFile=/dev/null' \
    --scp-flag='-o StrictHostKeyChecking=no'
}

# The key is unique to this pipeline run and is sent only through metadata as a
# public key; all subsequent builder access uses IAP-tunneled SSH.
pipeline_stage 1 "Validate inputs and prepare immutable image name $IMAGE_NAME"
SSH_KEY_DIR="$(mktemp -d)"
SSH_KEY_FILE="$SSH_KEY_DIR/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY_FILE"
SSH_PUBLIC_KEY="$(<"$SSH_KEY_FILE.pub")"
SERVICE_ACCOUNT_ARGS=(--no-service-account --no-scopes)
if [[ "$VS_INSTALL_MODE" == "offline-iso" ]]; then
  [[ "$BUILDER_SERVICE_ACCOUNT" == *@*.iam.gserviceaccount.com ]] || { log "[FAIL] A valid BUILDER_SERVICE_ACCOUNT is required for offline-iso"; exit 1; }
  [[ "$VS_MEDIA_URI" == gs://* ]] || { log "[FAIL] VS_MEDIA_URI must be a gs:// URI for offline-iso"; exit 1; }
  SERVICE_ACCOUNT_ARGS=(--service-account="$BUILDER_SERVICE_ACCOUNT" --scopes=cloud-platform)
fi

pipeline_stage 2 "Create Windows builder VM $BUILD_VM"
gcloud compute firewall-rules create "$SSH_FIREWALL" \
  --project="$PROJECT_ID" --network="$NETWORK" --direction=INGRESS \
  --action=ALLOW --rules=tcp:22 --source-ranges=35.235.240.0/20 \
  --target-tags="$SSH_TAG"
INSTANCE_TAGS="$SSH_TAG"
if [[ "$MANAGEMENT_MODE" == "true" ]]; then
  gcloud compute firewall-rules create "$RDP_FIREWALL" \
    --project="$PROJECT_ID" --network="$NETWORK" --direction=INGRESS \
    --action=ALLOW --rules=tcp:3389 --source-ranges=35.235.240.0/20 \
    --target-tags="$RDP_TAG"
  INSTANCE_TAGS+=",$RDP_TAG"
fi
gcloud compute instances create "$BUILD_VM" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --network="$NETWORK" \
  --subnet="$SUBNET" \
  --no-address \
  --machine-type=n2-standard-8 \
  --image-project=windows-cloud \
  --image-family="$SOURCE_IMAGE_FAMILY" \
  --boot-disk-size=200GB \
  --boot-disk-type=pd-balanced \
  --tags="$INSTANCE_TAGS" \
  "${SERVICE_ACCOUNT_ARGS[@]}" \
  --metadata="ephemeral-ssh-user=${SSH_USER},ephemeral-ssh-public-key=${SSH_PUBLIC_KEY},runner-version=${RUNNER_VERSION},vs-install-mode=${VS_INSTALL_MODE},vs-edition=${VS_EDITION},vs-media-uri=${VS_MEDIA_URI},vs-product-key-secret=${VS_PRODUCT_KEY_SECRET},vs-config-b64=${VS_CONFIG_B64},demo-project-b64=${DEMO_PROJECT_B64},demo-program-b64=${DEMO_PROGRAM_B64},demo-global-json-b64=${DEMO_GLOBAL_JSON_B64},project-mode=${PROJECT_MODE},project-setup-b64=${PROJECT_SETUP_B64},project-validate-b64=${PROJECT_VALIDATE_B64},project-health-path=${PROJECT_HEALTH_PATH},project-health-port=${PROJECT_HEALTH_PORT},app-version=${APP_VERSION},source-revision=${SOURCE_REVISION},app-index-b64=${APP_INDEX_B64},app-health-b64=${APP_HEALTH_B64}" \
  --metadata-from-file=windows-startup-script-ps1=infrastructure/image/windows/ssh-bootstrap.ps1
MANAGEMENT_VM_CREATED=true

if [[ "$MANAGEMENT_MODE" == "true" ]]; then
  wait_for_marker "$BUILD_VM" "SSH_BOOTSTRAP_READY" "SSH_BOOTSTRAP_FAILED:" 900
  log "[MANAGEMENT] Resetting the Windows password for gitops-admin on $BUILD_VM"
  gcloud compute reset-windows-password "$BUILD_VM" \
    --project="$PROJECT_ID" --zone="$ZONE" --user=gitops-admin --quiet
  printf '\nManagement VM %s is private and will be preserved.\n' "$BUILD_VM"
  printf 'Connect with: gcloud compute start-iap-tunnel %s 3389 --local-host-port=localhost:3389 --project=%s --zone=%s\n' \
    "$BUILD_VM" "$PROJECT_ID" "$ZONE"
  printf 'Then open an RDP client to localhost:3389 and sign in as gitops-admin.\n'
  printf 'The generated Windows password is shown in the reset-windows-password output above.\n'
  exit 0
fi

pipeline_stage 3 "Stream Windows provisioning and Visual Studio installation"
wait_for_marker "$BUILD_VM" "SSH_BOOTSTRAP_READY" "SSH_BOOTSTRAP_FAILED:" "$BUILD_TIMEOUT_SECONDS"
copy_to_vm "$BUILD_VM" infrastructure/image/windows/bootstrap.ps1 'C:/ImageBuild/bootstrap.ps1'
set +e
ssh_command "$BUILD_VM" 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:/ImageBuild/bootstrap.ps1' | tee "$BUILD_VM-ssh.log"
SSH_STATUS=${PIPESTATUS[0]}
set -e
if ! grep -Fq 'IMAGE_BUILD_COMPLETE' "$BUILD_VM-ssh.log"; then
  log "[$BUILD_VM] [FAIL] SSH provisioning did not report IMAGE_BUILD_COMPLETE (exit code $SSH_STATUS)"
  exit 1
fi
log "[$BUILD_VM] [PASS] SSH provisioning reported IMAGE_BUILD_COMPLETE"
log "[INFO] Provisioning completed; waiting for Sysprep shutdown"
wait_for_terminated "$BUILD_VM" 900

SOURCE_DISK="$(gcloud compute instances describe "$BUILD_VM" \
  --project="$PROJECT_ID" --zone="$ZONE" \
  --format='value(disks[0].source.basename())')"

pipeline_stage 4 "Capture immutable image $IMAGE_NAME"
# Capture only after the builder has shut down through GCE Sysprep, then validate
# the resulting image on a fresh VM before publishing success.
gcloud compute images create "$IMAGE_NAME" \
  --project="$PROJECT_ID" \
  --source-disk="$SOURCE_DISK" \
  --source-disk-zone="$ZONE" \
  --family="$IMAGE_FAMILY" \
  --description="Windows GitHub runner image built by Cloud Build ${BUILD_ID_RAW}"

pipeline_stage 5 "Create and stream smoke-test VM $TEST_VM"
gcloud compute instances create "$TEST_VM" \
  --project="$PROJECT_ID" \
  --zone="$ZONE" \
  --network="$NETWORK" \
  --subnet="$SUBNET" \
  --no-address \
  --machine-type=e2-standard-4 \
  --image="$IMAGE_NAME" \
  --boot-disk-size=200GB \
  --no-service-account \
  --no-scopes \
  --tags="$SSH_TAG" \
  --metadata="ephemeral-ssh-user=${SSH_USER},ephemeral-ssh-public-key=${SSH_PUBLIC_KEY}" \
  --metadata-from-file=windows-startup-script-ps1=infrastructure/image/windows/ssh-bootstrap.ps1

wait_for_marker "$TEST_VM" "SSH_BOOTSTRAP_READY" "SSH_BOOTSTRAP_FAILED:" "$TEST_TIMEOUT_SECONDS"
# Retrieve the ZIP from the freshly booted image while its one-time SSH access
# is active; only a successful smoke test is eligible for publication.
if [[ "$PROJECT_MODE" == "sample" && "$VS_INSTALL_MODE" != "disabled" && "$ARTIFACT_GCS_URI" != "disabled" ]]; then
  ARTIFACT_TEMP_DIR="$(mktemp -d)"
  ARTIFACT_LOCAL_PATH="$ARTIFACT_TEMP_DIR/SevenDemo.zip"
  copy_from_vm "$TEST_VM" 'C:/DemoArtifacts/SevenDemo.zip' "$ARTIFACT_LOCAL_PATH"
fi
copy_to_vm "$TEST_VM" infrastructure/image/windows/smoke-test.ps1 'C:/ImageBuild/smoke-test.ps1'
set +e
ssh_command "$TEST_VM" 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:/ImageBuild/smoke-test.ps1' | tee "$TEST_VM-ssh.log"
SSH_STATUS=${PIPESTATUS[0]}
set -e
if ! grep -Fq 'SMOKE_TEST_PASS' "$TEST_VM-ssh.log"; then
  log "[$TEST_VM] [FAIL] SSH smoke test did not report SMOKE_TEST_PASS (exit code $SSH_STATUS)"
  exit 1
fi
log "[$TEST_VM] [PASS] SSH smoke test reported SMOKE_TEST_PASS"
wait_for_terminated "$TEST_VM" 300

if [[ -n "$ARTIFACT_LOCAL_PATH" ]]; then
  log "[ARTIFACT] Uploading validated SevenDemo ZIP to $ARTIFACT_GCS_URI"
  gcloud storage cp "$ARTIFACT_LOCAL_PATH" "$ARTIFACT_GCS_URI" --project="$PROJECT_ID"
  log "[PASS] SevenDemo ZIP staged for GitHub Packages publication"
fi

BUILD_SUCCEEDED=true
pipeline_stage 6 "Publish build result"
log "IMAGE_NAME=$IMAGE_NAME"
log "IMAGE_FAMILY=$IMAGE_FAMILY"
log "APP_VERSION=$APP_VERSION"
log "SOURCE_REVISION=$SOURCE_REVISION"
log "[PASS] MVP image build and smoke test completed successfully"
