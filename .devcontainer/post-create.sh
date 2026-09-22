#!/usr/bin/env bash
# Initialize a Codespace: make scripts executable, report tool versions, and run syntax checks.
set -Eeuo pipefail

cd "${CONTAINER_WORKSPACE_FOLDER:-$(git rev-parse --show-toplevel)}"

find framework integrations .devcontainer -type f -name '*.sh' -exec chmod +x {} +

echo "Codespace toolchain"
printf '  %-12s %s\n' 'gcloud' "$(gcloud version | sed -n '1p')"
printf '  %-12s %s\n' 'gh' "$(gh --version | sed -n '1p')"
printf '  %-12s %s\n' 'PowerShell' "$(pwsh -NoLogo -NoProfile -Command "\$PSVersionTable.PSVersion.ToString()")"
printf '  %-12s %s\n' 'shellcheck' "$(shellcheck --version | awk '/^version:/{print $2}')"

./framework/validation/validate-repository.sh --syntax-only

cat <<'MESSAGE'

Codespace ready.

Next:
  1. Authenticate: gcloud auth login --no-launch-browser
  2. Configure:    ./framework/bootstrap/configure-codespace.sh PROJECT_ID us-central1-a
  3. Validate:     ./framework/validation/validate-repository.sh

No GCP credentials or Visual Studio product keys are stored in this repository.
MESSAGE
