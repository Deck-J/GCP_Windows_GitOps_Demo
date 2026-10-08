# Project hook for custom image smoke tests.
# Replace this file with checks that prove the application works on the captured image.
param(
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][string]$AppVersion
)

$ErrorActionPreference = 'Stop'

# Return a nonzero exit code when the application is not runnable.
Write-Output "PROJECT_VALIDATE_PASS|Custom validation hook completed for version $AppVersion"