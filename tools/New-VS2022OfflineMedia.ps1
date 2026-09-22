[CmdletBinding()]
param(
    [ValidateSet('Enterprise', 'Professional', 'Community')]
    [string]$Edition = 'Community',
    [string]$LayoutPath = 'C:\VS2022Layout',
    [string]$IsoPath = 'C:\VS2022Media\vs2022-community-layout.iso',
    [string]$ConfigPath = "$PSScriptRoot\..\projects\sample\config\vs2022.vsconfig",
    [string]$Language = 'en-US'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$bootstrapperUris = @{
    Enterprise   = 'https://aka.ms/vs/17/release/vs_enterprise.exe'
    Professional = 'https://aka.ms/vs/17/release/vs_professional.exe'
    Community    = 'https://aka.ms/vs/17/release/vs_community.exe'
}

New-Item -Path $LayoutPath -ItemType Directory -Force | Out-Null
New-Item -Path (Split-Path $IsoPath -Parent) -ItemType Directory -Force | Out-Null

$bootstrapper = Join-Path $LayoutPath "vs_$($Edition.ToLowerInvariant()).exe"
Invoke-WebRequest -Uri $bootstrapperUris[$Edition] -OutFile $bootstrapper

Write-Host "Creating the Visual Studio 2022 $Edition offline layout"
$layoutArgs = "--layout `"$LayoutPath`" --config `"$ConfigPath`" --lang $Language --includeRecommended --wait"
$layout = Start-Process -FilePath $bootstrapper -ArgumentList $layoutArgs -Wait -PassThru
if ($layout.ExitCode -notin @(0, 3010)) { throw "Layout creation failed with exit code $($layout.ExitCode)" }

Write-Host 'Verifying the offline layout'
$verify = Start-Process -FilePath $bootstrapper -ArgumentList "--layout `"$LayoutPath`" --verify --wait" -Wait -PassThru
if ($verify.ExitCode -ne 0) { throw "Layout verification failed with exit code $($verify.ExitCode)" }

$oscdimg = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools' `
    -Filter oscdimg.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $oscdimg) {
    throw 'oscdimg.exe was not found. Install the Windows ADK Deployment Tools feature.'
}

Write-Host "Creating ISO $IsoPath"
$iso = Start-Process -FilePath $oscdimg.FullName -ArgumentList "-m -o -u2 -udfver102 `"$LayoutPath`" `"$IsoPath`"" -Wait -PassThru
if ($iso.ExitCode -ne 0) { throw "ISO creation failed with exit code $($iso.ExitCode)" }

$hash = Get-FileHash -Path $IsoPath -Algorithm SHA256
Write-Host "ISO: $IsoPath"
Write-Host "SHA256: $($hash.Hash)"
Write-Host 'Upload the ISO to the restricted GCS location configured as VS_MEDIA_URI.'
