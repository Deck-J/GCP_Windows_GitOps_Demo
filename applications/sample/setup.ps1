# Project hook for custom image builds.
# Replace this file with project-specific installation and configuration steps.
param(
    [Parameter(Mandatory = $true)][string]$BuildRoot,
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][string]$AppVersion,
    [Parameter(Mandatory = $true)][string]$SourceRevision
)

$ErrorActionPreference = 'Stop'

# Install the application and its dependencies here. Keep secrets in Secret Manager.
Write-Output "PROJECT_SETUP_PASS|Custom setup hook completed for version $AppVersion ($SourceRevision)"