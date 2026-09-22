# Provision the temporary Windows builder VM and turn it into a reusable runner image.
# Installs IIS/toolchains, optionally reads a product key from Secret Manager, validates the demo,
# stages the GitHub runner without credentials, then syspreps the VM for image capture.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-DemoStage([int]$Number, [int]$Total, [string]$Message) {
    Write-Output ("DEMO_STAGE|{0:D2}|{1:D2}|{2}" -f $Number, $Total, $Message)
}

function Write-DemoPass([string]$Name, [string]$Message) {
    Write-Output "DEMO_PASS|$Name|$Message"
}

function Write-DemoInfo([string]$Message) {
    Write-Output "DEMO_INFO|$Message"
}

function Get-MetadataValue([string]$Key, [string]$DefaultValue) {
    try {
        $headers = @{ 'Metadata-Flavor' = 'Google' }
        return Invoke-RestMethod -Headers $headers -Uri "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$Key"
    }
    catch {
        return $DefaultValue
    }
}

function Invoke-Installer([string]$Path, [string]$Arguments, [int[]]$SuccessCodes = @(0, 3010)) {
    $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
    if ($process.ExitCode -notin $SuccessCodes) {
        throw "Installer $Path exited with code $($process.ExitCode)"
    }
}

function Get-GcpAccessToken {
    $headers = @{ 'Metadata-Flavor' = 'Google' }
    $token = Invoke-RestMethod -Headers $headers -Uri 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token'
    return $token.access_token
}

function Get-GcpProjectId {
    $headers = @{ 'Metadata-Flavor' = 'Google' }
    return Invoke-RestMethod -Headers $headers -Uri 'http://metadata.google.internal/computeMetadata/v1/project/project-id'
}

function Get-SecretValue([string]$SecretName) {
    $token = Get-GcpAccessToken
    $projectId = Get-GcpProjectId
    $headers = @{ Authorization = "Bearer $token" }
    $uri = "https://secretmanager.googleapis.com/v1/projects/$projectId/secrets/$SecretName/versions/latest`:access"
    $response = Invoke-RestMethod -Method Get -Headers $headers -Uri $uri
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($response.payload.data)).Trim()
}

function Copy-GcsObject([string]$GcsUri, [string]$Destination) {
    if ($GcsUri -notmatch '^gs://([^/]+)/(.+)$') { throw 'Visual Studio media must use a gs:// URI' }
    $bucket = $Matches[1]
    $objectName = [Uri]::EscapeDataString($Matches[2])
    $token = Get-GcpAccessToken
    $headers = @{ Authorization = "Bearer $token" }
    $uri = "https://storage.googleapis.com/storage/v1/b/$bucket/o/$objectName`?alt=media"
    Invoke-WebRequest -Headers $headers -Uri $uri -OutFile $Destination
}

try {
    $work = 'C:\ImageBuild'
    New-Item -Path $work -ItemType Directory -Force | Out-Null
    $projectMode = (Get-MetadataValue 'project-mode' 'sample').ToLowerInvariant()
    if ($projectMode -notin @('sample', 'custom')) { throw "Unsupported project mode: $projectMode" }
    $projectSetupPath = Join-Path $work 'project-setup.ps1'
    $projectValidatePath = Join-Path $work 'project-validate.ps1'
    if ($projectMode -eq 'custom') {
        [IO.File]::WriteAllBytes($projectSetupPath, [Convert]::FromBase64String((Get-MetadataValue 'project-setup-b64' '')))
        [IO.File]::WriteAllBytes($projectValidatePath, [Convert]::FromBase64String((Get-MetadataValue 'project-validate-b64' '')))
    }

    Write-DemoStage 1 9 'Install IIS and publish the versioned web application'
    Install-WindowsFeature Web-Server -IncludeManagementTools | Out-Null
    $appVersion = Get-MetadataValue 'app-version' 'unknown'
    $sourceRevision = Get-MetadataValue 'source-revision' 'unknown'
    $indexBytes = [Convert]::FromBase64String((Get-MetadataValue 'app-index-b64' ''))
    $healthBytes = [Convert]::FromBase64String((Get-MetadataValue 'app-health-b64' ''))
    $indexContent = [Text.Encoding]::UTF8.GetString($indexBytes)
    $healthContent = [Text.Encoding]::UTF8.GetString($healthBytes)
    $indexContent = $indexContent.Replace('__APP_VERSION__', $appVersion).Replace('__SOURCE_REVISION__', $sourceRevision)
    $healthContent = $healthContent.Replace('__APP_VERSION__', $appVersion)
    Set-Content -Path 'C:\inetpub\wwwroot\index.html' -Value $indexContent -Encoding UTF8
    Set-Content -Path 'C:\inetpub\wwwroot\health.html' -Value $healthContent -Encoding UTF8
    Set-Content -Path 'C:\inetpub\wwwroot\version.json' -Value "{`"version`":`"$appVersion`",`"revision`":`"$sourceRevision`"}" -Encoding UTF8
    Write-DemoPass 'IIS' "Published application version $appVersion"

    Write-DemoStage 2 9 'Install Git for Windows'
    $gitInstaller = Join-Path $work 'Git-64-bit.exe'
    $gitVersion = '2.51.0'
    $gitUri = "https://github.com/git-for-windows/git/releases/download/v$gitVersion.windows.1/Git-$gitVersion-64-bit.exe"
    Invoke-WebRequest -Uri $gitUri -OutFile $gitInstaller
    Invoke-Installer $gitInstaller '/VERYSILENT /NORESTART /NOCANCEL /SP-'
    Write-DemoPass 'Git' "Installed Git for Windows $gitVersion"

    Write-DemoStage 3 9 'Install pinned .NET 7 SDK for the C# 7 demonstration'
    $dotnetInstall = Join-Path $work 'dotnet-install.ps1'
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $dotnetInstall
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dotnetInstall -Version '7.0.410' -InstallDir 'C:\Program Files\dotnet'
    if ($LASTEXITCODE -ne 0) { throw ".NET 7 installer exited with code $LASTEXITCODE" }
    Write-DemoPass '.NET 7' 'Installed SDK 7.0.410'

    Write-DemoStage 4 9 'Install .NET 8 SDK for current runner compatibility'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dotnetInstall -Channel '8.0' -InstallDir 'C:\Program Files\dotnet'
    if ($LASTEXITCODE -ne 0) { throw ".NET installer exited with code $LASTEXITCODE" }
    [Environment]::SetEnvironmentVariable('PATH', $env:PATH + ';C:\Program Files\dotnet', 'Machine')
    Write-DemoPass '.NET 8' 'Installed current .NET 8 channel'

    $vsInstallMode = (Get-MetadataValue 'vs-install-mode' 'web-community').ToLowerInvariant()
    $vsEdition = (Get-MetadataValue 'vs-edition' 'enterprise').ToLowerInvariant()
    $vsInstallRoot = $null

    Write-DemoStage 5 9 "Install Visual Studio 2022 ($vsInstallMode / $vsEdition)"
    switch ($vsInstallMode) {
        'disabled' {
            Write-DemoInfo 'Visual Studio installation is disabled'
        }
        'web-buildtools' {
            Write-DemoInfo 'Downloading Visual Studio 2022 Build Tools from Microsoft'
            $vsInstaller = Join-Path $work 'vs_BuildTools.exe'
            Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile $vsInstaller
            $vsInstallRoot = 'C:\BuildTools'
            $vsArgs = '--quiet --wait --norestart --nocache --installPath C:\BuildTools --add Microsoft.VisualStudio.Workload.MSBuildTools --add Microsoft.VisualStudio.Workload.NetWeb --includeRecommended'
            Invoke-Installer $vsInstaller $vsArgs
        }
        'web-community' {
            Write-DemoInfo 'Downloading Visual Studio 2022 Community from Microsoft'
            $vsInstaller = Join-Path $work 'vs_Community.exe'
            Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_community.exe' -OutFile $vsInstaller
            $configPath = Join-Path $work 'vs2022.vsconfig'
            $configBase64 = Get-MetadataValue 'vs-config-b64' ''
            if ([string]::IsNullOrWhiteSpace($configBase64)) { throw 'Visual Studio configuration is missing' }
            [IO.File]::WriteAllBytes($configPath, [Convert]::FromBase64String($configBase64))
            $vsInstallRoot = 'C:\VisualStudio\2022\Community'
            $vsArgs = "--quiet --wait --norestart --nocache --installPath `"$vsInstallRoot`" --config `"$configPath`""
            Invoke-Installer $vsInstaller $vsArgs
        }
        'offline-iso' {
            if ($vsEdition -notin @('enterprise', 'professional', 'community')) {
                throw "Unsupported full Visual Studio edition: $vsEdition"
            }

            $mediaUri = Get-MetadataValue 'vs-media-uri' ''
            $secretName = Get-MetadataValue 'vs-product-key-secret' ''
            $configBase64 = Get-MetadataValue 'vs-config-b64' ''
            if ([string]::IsNullOrWhiteSpace($mediaUri)) { throw 'Visual Studio media URI is missing' }
            if ([string]::IsNullOrWhiteSpace($configBase64)) { throw 'Visual Studio configuration is missing' }

            $isoPath = Join-Path $work 'vs2022-layout.iso'
            $configPath = Join-Path $work 'vs2022.vsconfig'
            [IO.File]::WriteAllBytes($configPath, [Convert]::FromBase64String($configBase64))

            Write-DemoInfo 'Downloading the approved Visual Studio 2022 offline-layout ISO'
            Copy-GcsObject -GcsUri $mediaUri -Destination $isoPath

            Write-DemoInfo 'Mounting the Visual Studio 2022 offline-layout ISO'
            $diskImage = Mount-DiskImage -ImagePath $isoPath -PassThru
            try {
                $volume = $diskImage | Get-Volume
                if (-not $volume.DriveLetter) { throw 'Mounted Visual Studio ISO has no drive letter' }
                $mediaRoot = "$($volume.DriveLetter):\"
                $bootstrapperName = "vs_$vsEdition.exe"
                $bootstrapper = Get-ChildItem -Path $mediaRoot -Filter $bootstrapperName -File -Recurse | Select-Object -First 1
                if (-not $bootstrapper) { throw "$bootstrapperName was not found on the mounted ISO" }

                $editionName = (Get-Culture).TextInfo.ToTitleCase($vsEdition)
                $vsInstallRoot = "C:\VisualStudio\2022\$editionName"
                $arguments = "--noWeb --quiet --wait --norestart --nocache --installPath `"$vsInstallRoot`" --config `"$configPath`""

                if ($vsEdition -ne 'community') {
                    if ([string]::IsNullOrWhiteSpace($secretName)) { throw 'A Secret Manager product-key secret is required' }
                    Write-DemoInfo 'Reading the Visual Studio product key from Secret Manager'
                    $productKey = (Get-SecretValue -SecretName $secretName) -replace '-', ''
                    if ($productKey -notmatch '^[A-Za-z0-9]{25}$') { throw 'The Visual Studio product key must contain 25 alphanumeric characters' }
                    $arguments += " --productKey $productKey"
                }

                Write-DemoInfo "Installing Visual Studio 2022 $editionName from mounted media"
                Invoke-Installer -Path $bootstrapper.FullName -Arguments $arguments
                $productKey = $null
                $arguments = $null
            }
            finally {
                Write-DemoInfo 'Dismounting the Visual Studio installation media'
                Dismount-DiskImage -ImagePath $isoPath -ErrorAction SilentlyContinue
            }
        }
        default {
            throw "Unsupported Visual Studio installation mode: $vsInstallMode"
        }
    }

    if ($vsInstallMode -ne 'disabled') {
        $msbuild = Join-Path $vsInstallRoot 'MSBuild\Current\Bin\MSBuild.exe'
        if (-not (Test-Path $msbuild)) { throw 'Visual Studio installation completed but MSBuild was not found' }
        if ($vsInstallMode -in @('web-community', 'offline-iso')) {
            $devenv = Join-Path $vsInstallRoot 'Common7\IDE\devenv.exe'
            if (-not (Test-Path $devenv)) { throw 'Full Visual Studio installation completed but devenv.exe was not found' }
        }
        Write-DemoPass 'Visual Studio' "Validated MSBuild and $vsEdition installation"
    }
    else {
        Write-DemoPass 'Visual Studio' 'Skipped by configuration'
    }
    New-Item -Path 'C:\ImageMetadata' -ItemType Directory -Force | Out-Null
    $metadataInstallPath = if ($vsInstallRoot) { $vsInstallRoot.Replace('\', '\\') } else { '' }
    Set-Content -Path 'C:\ImageMetadata\visual-studio.json' -Encoding UTF8 -Value "{`"mode`":`"$vsInstallMode`",`"edition`":`"$vsEdition`",`"installPath`":`"$metadataInstallPath`"}"

    if ($projectMode -eq 'custom') {
        Write-DemoStage 6 9 'Run the project-provided image setup and validation hooks'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $projectSetupPath `
            -BuildRoot $work -InstallRoot 'C:\Project' `
            -AppVersion $appVersion -SourceRevision $sourceRevision
        if ($LASTEXITCODE -ne 0) { throw "Project setup hook failed with code $LASTEXITCODE" }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $projectValidatePath `
            -InstallRoot 'C:\Project' -AppVersion $appVersion
        if ($LASTEXITCODE -ne 0) { throw "Project validation hook failed with code $LASTEXITCODE" }
        Set-Content -Path 'C:\ImageMetadata\project-validation.txt' -Value 'passed' -Encoding ASCII
        Write-DemoPass 'Project hooks' 'Custom setup and validation hooks completed'
    }
    else {
        Write-DemoStage 6 9 'Compile and execute the repository-stored .NET 7 / C# 7 project'
    }
    if ($projectMode -eq 'sample' -and $vsInstallMode -ne 'disabled') {
        Write-DemoInfo 'Restoring SevenDemo'
        $demoSource = Join-Path $work 'SevenDemo'
        New-Item -Path $demoSource -ItemType Directory -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $demoSource 'SevenDemo.csproj'), [Convert]::FromBase64String((Get-MetadataValue 'demo-project-b64' '')))
        [IO.File]::WriteAllBytes((Join-Path $demoSource 'Program.cs'), [Convert]::FromBase64String((Get-MetadataValue 'demo-program-b64' '')))
        [IO.File]::WriteAllBytes((Join-Path $demoSource 'global.json'), [Convert]::FromBase64String((Get-MetadataValue 'demo-global-json-b64' '')))

        $demoPublish = 'C:\DemoArtifacts\SevenDemo'
        New-Item -Path $demoPublish -ItemType Directory -Force | Out-Null
        $demoProject = Join-Path $demoSource 'SevenDemo.csproj'

        Write-DemoInfo 'Compiling SevenDemo with Visual Studio MSBuild'
        & $msbuild $demoProject /restore /t:Publish /p:Configuration=Release "/p:PublishDir=$demoPublish\"
        if ($LASTEXITCODE -ne 0) { throw "SevenDemo compilation failed with code $LASTEXITCODE" }

        $demoDll = Join-Path $demoPublish 'SevenDemo.dll'
        if (-not (Test-Path $demoDll)) { throw 'SevenDemo.dll was not produced' }
        $demoOutput = (& 'C:\Program Files\dotnet\dotnet.exe' $demoDll | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $demoOutput -notmatch 'SevenDemo OK.*\.NET 7.*C# 7\.0') {
            throw "SevenDemo execution validation failed: $demoOutput"
        }

        [ordered]@{
            project = 'SevenDemo'
            targetFramework = 'net7.0'
            languageVersion = '7.0'
            sdkVersion = '7.0.410'
            compiler = 'Visual Studio 2022 MSBuild'
            visualStudioEdition = $vsEdition
            output = $demoOutput
        } | ConvertTo-Json | Set-Content -Path 'C:\ImageMetadata\seven-demo-build.json' -Encoding UTF8
        Write-DemoPass 'SevenDemo' $demoOutput
    }
    elseif ($projectMode -eq 'sample') {
        Write-DemoPass 'SevenDemo' 'Skipped because Visual Studio is disabled'
    }

    Write-DemoStage 7 9 'Stage pinned GitHub Actions runner files'
    $runnerVersion = Get-MetadataValue 'runner-version' '2.328.0'
    $runnerRoot = 'C:\actions-runner'
    $runnerZip = Join-Path $work 'actions-runner.zip'
    New-Item -Path $runnerRoot -ItemType Directory -Force | Out-Null
    $runnerUri = "https://github.com/actions/runner/releases/download/v$runnerVersion/actions-runner-win-x64-$runnerVersion.zip"
    Invoke-WebRequest -Uri $runnerUri -OutFile $runnerZip
    Expand-Archive -Path $runnerZip -DestinationPath $runnerRoot -Force
    Write-DemoPass 'GitHub runner' "Staged runner $runnerVersion without registration credentials"

    Write-DemoStage 8 9 'Validate IIS, tools, project output and application health'
    if ((Get-WindowsFeature Web-Server).InstallState -ne 'Installed') { throw 'IIS is not installed' }
    $healthPath = Get-MetadataValue 'project-health-path' '/health.html'
    $healthPort = Get-MetadataValue 'project-health-port' '80'
    $healthResponse = Invoke-WebRequest -UseBasicParsing -Uri "http://localhost:$healthPort$healthPath"
    if ($healthResponse.StatusCode -ne 200) { throw 'Application health check failed' }
    if (-not (Test-Path 'C:\Program Files\Git\cmd\git.exe')) { throw 'Git is not installed' }
    if (-not (Test-Path 'C:\Program Files\dotnet\dotnet.exe')) { throw '.NET SDK is not installed' }
    if (-not (Test-Path 'C:\actions-runner\Runner.Listener.exe')) { throw 'GitHub runner files are missing' }
    if ($vsInstallMode -ne 'disabled' -and -not (Test-Path 'C:\ImageMetadata\visual-studio.json')) { throw 'Visual Studio installation metadata is missing' }
    if ($projectMode -eq 'sample' -and $vsInstallMode -ne 'disabled' -and -not (Test-Path 'C:\ImageMetadata\seven-demo-build.json')) { throw 'SevenDemo build proof is missing' }
    if ($projectMode -eq 'custom' -and -not (Test-Path 'C:\ImageMetadata\project-validation.txt')) { throw 'Project validation proof is missing' }
    Write-DemoPass 'Image validation' 'All required image checks passed'

    Write-DemoStage 9 9 'Clean temporary files and run Sysprep'
    Remove-Item -Path $work -Recurse -Force
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue

    # Cloud Build waits for this marker before it begins waiting for shutdown.
    Write-Output 'IMAGE_BUILD_COMPLETE'

    $sysprepBat = Join-Path $env:ProgramFiles 'Google\Compute Engine\sysprep\gcesysprep.bat'
    $sysprepPs1 = Join-Path $env:ProgramFiles 'Google\Compute Engine\sysprep\GCESysprep.ps1'
    if (Test-Path $sysprepBat) {
        & $sysprepBat
    }
    elseif (Test-Path $sysprepPs1) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sysprepPs1
    }
    else {
        throw 'Google Compute Engine Sysprep utility was not found'
    }
}
catch {
    Write-Output "IMAGE_BUILD_FAILED: $($_.Exception.Message)"
    throw
}
