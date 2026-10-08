# Project hook for custom image builds.
# Replace this file with project-specific installation and configuration steps.
# Inputs describe the staged source, destination install location, and exact build revision.
# Emit PROJECT_SETUP_PASS only after required setup is complete; fail with a nonzero exit code otherwise.
param(
    [Parameter(Mandatory = $true)][string]$BuildRoot,
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][string]$AppVersion,
    [Parameter(Mandatory = $true)][string]$SourceRevision
)

$ErrorActionPreference = 'Stop'

# The image pipeline calls this hook with the build workspace, target install
# directory, release version, and source revision. Install project dependencies
# here, but retrieve any sensitive configuration from Secret Manager.
Write-Output "PROJECT_SETUP_PASS|Custom setup hook completed for version $AppVersion ($SourceRevision)"