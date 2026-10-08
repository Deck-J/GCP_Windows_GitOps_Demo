#!/usr/bin/env bash
# Initialize a Codespace: make scripts executable, report tool versions, and run syntax checks.
set -Eeuo pipefail

cd "${CONTAINER_WORKSPACE_FOLDER:-$(git rev-parse --show-toplevel)}"

# Git checkouts may not retain executable bits consistently across environments.
# Restore script permissions before invoking validation or showing the next steps.
find bootstrap infrastructure validation integrations .devcontainer -type f -name '*.sh' -exec chmod +x {} +

# Report the tools expected by the setup and validation commands; these checks
# make a missing dev-container feature obvious before a user starts provisioning.
echo "Codespace toolchain"
printf '  %-12s %s\n' 'gcloud' "$(gcloud version | sed -n '1p')"
printf '  %-12s %s\n' 'gh' "$(gh --version | sed -n '1p')"
printf '  %-12s %s\n' 'PowerShell' "$(pwsh -NoLogo -NoProfile -Command "\$PSVersionTable.PSVersion.ToString()")"
printf '  %-12s %s\n' 'shellcheck' "$(shellcheck --version | awk '/^version:/{print $2}')"

# Keep container creation quick: syntax checks run here, while full linting is
# available as an explicit follow-up after the Codespace is ready.
./validation/validate-repository.sh --syntax-only

cat <<'MESSAGE'

Codespace ready.

Next:
  1. Authenticate: gcloud auth login --no-launch-browser
  2. Configure:    ./bootstrap/codespaces/configure-codespace.sh PROJECT_ID us-central1-a
  3. Validate:     ./validation/validate-repository.sh

No GCP credentials or Visual Studio product keys are stored in this repository.
MESSAGE
