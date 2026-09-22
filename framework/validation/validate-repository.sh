#!/usr/bin/env bash
# Run local syntax and optional lint checks for Bash, PowerShell, and YAML repository files.
set -Eeuo pipefail

MODE="${1:-full}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

mapfile -t BASH_FILES < <(find framework integrations .devcontainer -type f -name '*.sh' -print | sort)
for file in "${BASH_FILES[@]}"; do
  bash -n "$file"
done
echo "[PASS] Bash syntax (${#BASH_FILES[@]} files)"

if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoLogo -NoProfile -File - <<'POWERSHELL'
$failed = $false
Get-ChildItem -Path framework, integrations, projects -Filter *.ps1 -Recurse | ForEach-Object {
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
else
  echo '[WARN] PowerShell is unavailable; skipped PowerShell parser validation'
fi

if command -v yamllint >/dev/null 2>&1; then
  yamllint -d '{extends: relaxed, rules: {line-length: disable, truthy: disable}}' \
    pipelines/cloudbuild-image.yaml pipelines/cloudbuild-deploy.yaml .github/workflows
  echo '[PASS] YAML validation'
else
  echo '[WARN] yamllint is unavailable; skipped YAML validation'
fi

if [[ "$MODE" != "--syntax-only" ]]; then
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x "${BASH_FILES[@]}"
    echo '[PASS] ShellCheck'
  else
    echo '[WARN] ShellCheck is unavailable; skipped lint validation'
  fi
fi

echo '[PASS] Repository validation complete'
