#!/usr/bin/env bash
# Run local syntax and optional lint checks for Bash, PowerShell, and YAML repository files.
set -Eeuo pipefail

MODE="${1:-full}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mapfile -t BASH_FILES < <(find bootstrap infrastructure validation integrations .devcontainer -type f -name '*.sh' -print | sort)
# Parse every checked-in shell script without executing cloud or destructive commands.
for file in "${BASH_FILES[@]}"; do
  bash -n "$file"
done
echo "[PASS] Bash syntax (${#BASH_FILES[@]} files)"

for environment in dev prod; do
  # These are intentional demo topologies; fail validation if docs and
  # deployment behavior drift from the requested two-node Dev/four-node Prod.
  manifest="environments/$environment/deployment.env"
  expected_nodes=2
  [[ "$environment" == "prod" ]] && expected_nodes=4
  actual_nodes="$(sed -n 's/^NODE_COUNT=//p' "$manifest")"
  if [[ "$actual_nodes" != "$expected_nodes" ]]; then
    echo "[FAIL] $manifest must set NODE_COUNT=$expected_nodes (found: ${actual_nodes:-missing})" >&2
    exit 1
  fi
done
echo '[PASS] Dev and Prod worker counts'

if command -v pwsh >/dev/null 2>&1; then
  # PowerShell's parser provides syntax diagnostics without running the scripts.
  POWERSHELL_CHECK="$(mktemp)"
  cat >"$POWERSHELL_CHECK" <<'POWERSHELL'
$failed = $false
Get-ChildItem -Path bootstrap, infrastructure, integrations, applications -Filter *.ps1 -Recurse | ForEach-Object {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $failed = $true
        $errors | ForEach-Object { Write-Error "$($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)" }
    }
}
if ($failed) { exit 1 }
Write-Output '[PASS] PowerShell syntax'
POWERSHELL
  if ! pwsh -NoLogo -NoProfile -File "$POWERSHELL_CHECK"; then
    rm -f "$POWERSHELL_CHECK"
    exit 1
  fi
  rm -f "$POWERSHELL_CHECK"
else
  echo '[WARN] PowerShell is unavailable; skipped PowerShell parser validation'
fi

if command -v yamllint >/dev/null 2>&1; then
  # Relax cosmetic rules while still catching malformed Cloud Build YAML.
  yamllint -d '{extends: relaxed, rules: {line-length: disable, truthy: disable}}' \
    cloudbuild/*.yaml
  echo '[PASS] YAML validation'
else
  echo '[WARN] yamllint is unavailable; skipped YAML validation'
fi

if command -v actionlint >/dev/null 2>&1; then
  actionlint .github/workflows/*.yml
  echo '[PASS] GitHub Actions workflow validation'
else
  echo '[WARN] actionlint is unavailable; skipped GitHub Actions semantic validation'
fi

if [[ "$MODE" != "--syntax-only" ]]; then
  # Full mode adds static shell analysis; syntax-only is used during bootstrap.
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "${BASH_FILES[@]}"
    echo '[PASS] ShellCheck'
  else
    echo '[WARN] ShellCheck is unavailable; skipped lint validation'
  fi
fi

echo '[PASS] Repository validation complete'
