# Project hook for custom image smoke tests.
# Replace this file with checks that prove the application works on the captured image.
param(
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][string]$AppVersion
)

$ErrorActionPreference = 'Stop'

# The image builder and post-capture smoke VM both call this hook. Replace the
# placeholder with deterministic checks and throw/exit nonzero on any failure.
Write-Output "PROJECT_VALIDATE_PASS|Custom validation hook completed for version $AppVersion"