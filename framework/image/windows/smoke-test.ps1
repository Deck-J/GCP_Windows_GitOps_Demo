# Validate the captured Windows image by checking installed files and tools, running SevenDemo,
# requesting the IIS health endpoint, and shutting down the temporary smoke-test VM.
$ErrorActionPreference = 'Stop'

function Write-DemoStage([int]$Number, [int]$Total, [string]$Message) {
    Write-Output ("DEMO_STAGE|{0:D2}|{1:D2}|{2}" -f $Number, $Total, $Message)
}

function Write-DemoPass([string]$Name, [string]$Message) {
    Write-Output "DEMO_PASS|$Name|$Message"
}

function Get-MetadataValue([string]$Key, [string]$DefaultValue = '') {
    try {
        $headers = @{ 'Metadata-Flavor' = 'Google' }
        return Invoke-RestMethod -Headers $headers -Uri "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$Key"
    }
    catch {
        return $DefaultValue
    }
}

try {
    $projectMode = (Get-MetadataValue 'project-mode' 'sample').ToLowerInvariant()
    Write-DemoStage 1 4 'Verify required files and installed Windows features'
    $checks = [ordered]@{
        IIS          = ((Get-WindowsFeature Web-Server).InstallState -eq 'Installed')
        WebPage      = if ($projectMode -eq 'sample') { Test-Path 'C:\inetpub\wwwroot\index.html' } else { $true }
        HealthPage   = if ($projectMode -eq 'sample') { Test-Path 'C:\inetpub\wwwroot\health.html' } else { $true }
        VersionFile  = if ($projectMode -eq 'sample') { Test-Path 'C:\inetpub\wwwroot\version.json' } else { $true }
        Git          = (Test-Path 'C:\Program Files\Git\cmd\git.exe')
        DotNet       = (Test-Path 'C:\Program Files\dotnet\dotnet.exe')
        GitHubRunner = (Test-Path 'C:\actions-runner\Runner.Listener.exe')
        VSMetadata   = (Test-Path 'C:\ImageMetadata\visual-studio.json')
        ProjectProof = if ($projectMode -eq 'sample') { Test-Path 'C:\ImageMetadata\seven-demo-build.json' } else { Test-Path 'C:\ImageMetadata\project-validation.txt' }
    }

    $failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key })
    if ($failed.Count -gt 0) {
        throw "Failed checks: $($failed -join ', ')"
    }
    foreach ($check in $checks.GetEnumerator()) {
        Write-DemoPass "Smoke $($check.Key)" 'Present'
    }

    Write-DemoStage 2 4 'Execute Git, .NET and Visual Studio toolchain checks'
    & 'C:\Program Files\Git\cmd\git.exe' --version
    & 'C:\Program Files\dotnet\dotnet.exe' --info
    if ($projectMode -eq 'sample' -and (Test-Path 'C:\ImageMetadata\visual-studio.json')) {
        $vs = Get-Content 'C:\ImageMetadata\visual-studio.json' -Raw | ConvertFrom-Json
        if ($vs.mode -ne 'disabled') {
            $msbuild = Join-Path $vs.installPath 'MSBuild\Current\Bin\MSBuild.exe'
            if (-not (Test-Path $msbuild)) { throw 'MSBuild validation failed in the smoke-test VM' }
            & $msbuild -version
            if ($vs.mode -in @('web-community', 'offline-iso')) {
                $devenv = Join-Path $vs.installPath 'Common7\IDE\devenv.exe'
                if (-not (Test-Path $devenv)) { throw 'Visual Studio IDE validation failed in the smoke-test VM' }
                Write-DemoPass 'Visual Studio IDE' 'devenv.exe is present'
            }
            Write-DemoPass 'MSBuild' 'MSBuild executed successfully'
            Write-DemoStage 3 4 'Execute compiled .NET 7 / C# 7 demonstration application'
            $demoDll = 'C:\DemoArtifacts\SevenDemo\SevenDemo.dll'
            if (-not (Test-Path $demoDll)) { throw 'SevenDemo.dll is missing' }
            $demoOutput = (& 'C:\Program Files\dotnet\dotnet.exe' $demoDll | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or $demoOutput -notmatch 'SevenDemo OK.*\.NET 7.*C# 7\.0') {
                throw 'The .NET 7 / C# 7 compiled demo failed to execute'
            }
            Write-DemoPass 'SevenDemo execution' $demoOutput
        }
    }
    Write-DemoStage 4 4 'Request application health endpoint'
    $healthPath = Get-MetadataValue 'project-health-path' '/health.html'
    $healthPort = Get-MetadataValue 'project-health-port' '80'
    $health = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$healthPort$healthPath"
    if ($health.StatusCode -ne 200) {
        throw 'Application health request failed'
    }
    Write-DemoPass 'IIS health' 'HTTP 200 and healthy response received'
    Write-Output 'SMOKE_TEST_PASS'
}
catch {
    Write-Output "SMOKE_TEST_FAIL: $($_.Exception.Message)"
    throw
}
finally {
    Stop-Computer -Force
}
