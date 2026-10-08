# Configure Dynatrace on an ephemeral application VM at startup.
# Reads only the token secret name from metadata, retrieves the token from Secret Manager,
# validates the signed installer, installs OneAgent, and reports readiness through serial output.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-DynatraceStage([int]$Number, [int]$Total, [string]$Message) {
    Write-Output ("DYNATRACE_STAGE|{0:D2}|{1:D2}|{2}" -f $Number, $Total, $Message)
}

function Write-DynatracePass([string]$Name, [string]$Message) {
    Write-Output "DYNATRACE_PASS|$Name|$Message"
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

function Get-GcpAccessToken {
    $headers = @{ 'Metadata-Flavor' = 'Google' }
    $response = Invoke-RestMethod -Headers $headers -Uri 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token'
    return $response.access_token
}

function Get-GcpProjectId {
    $headers = @{ 'Metadata-Flavor' = 'Google' }
    return Invoke-RestMethod -Headers $headers -Uri 'http://metadata.google.internal/computeMetadata/v1/project/project-id'
}

function Get-SecretValue([string]$SecretName) {
    # The runtime VM identity retrieves the latest secret version; only the
    # secret resource name is passed as instance metadata.
    if ($SecretName -notmatch '^[A-Za-z0-9_-]+$') { throw 'Dynatrace secret name is invalid' }
    $gcpToken = Get-GcpAccessToken
    $projectId = Get-GcpProjectId
    $headers = @{ Authorization = "Bearer $gcpToken" }
    $uri = "https://secretmanager.googleapis.com/v1/projects/$projectId/secrets/$SecretName/versions/latest`:access"
    $response = Invoke-RestMethod -Method Get -Headers $headers -Uri $uri
    $gcpToken = $null
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($response.payload.data)).Trim()
}

try {
    # Runtime metadata carries only the secret's name. Fetch the actual token
    # using the VM identity so no reusable credential is baked into the image.
    $enabled = (Get-MetadataValue 'dynatrace-enabled' 'false').ToLowerInvariant()
    if ($enabled -ne 'true') {
        Write-Output 'DYNATRACE_DISABLED'
        exit 0
    }

    $environmentUrl = (Get-MetadataValue 'dynatrace-environment-url').TrimEnd('/')
    $secretName = Get-MetadataValue 'dynatrace-token-secret'
    $monitoringMode = (Get-MetadataValue 'dynatrace-monitoring-mode' 'fullstack').ToLowerInvariant()
    $hostGroup = Get-MetadataValue 'dynatrace-host-group' 'gcp-windows-demo'
    $networkZone = Get-MetadataValue 'dynatrace-network-zone'
    $appColor = Get-MetadataValue 'app-color' 'unknown'
    $appVersion = Get-MetadataValue 'app-version' 'unknown'

    # Reject invalid or incomplete configuration before downloading an
    # installer or sending an authenticated request to the Dynatrace tenant.
    if ($environmentUrl -notmatch '^https://[^/]+') { throw 'Dynatrace environment URL must use HTTPS' }
    if ([string]::IsNullOrWhiteSpace($secretName)) { throw 'Dynatrace token secret is required' }
    if ($monitoringMode -notin @('fullstack', 'infra-only', 'discovery')) { throw 'Unsupported Dynatrace monitoring mode' }
    if ($hostGroup -notmatch '^(?!dt\.)[A-Za-z0-9_.-]{1,100}$') { throw 'Dynatrace host group is invalid' }
    if ($networkZone -and $networkZone -notmatch '^[A-Za-z0-9_.-]{1,256}$') { throw 'Dynatrace network zone is invalid' }
    if ($appColor -notmatch '^[A-Za-z0-9_.-]+$' -or $appVersion -notmatch '^[A-Za-z0-9_.+-]+$') {
        throw 'Application metadata contains unsupported characters'
    }

    $work = 'C:\DynatraceBootstrap'
    New-Item -Path $work -ItemType Directory -Force | Out-Null
    $installer = Join-Path $work 'Dynatrace-OneAgent-Windows.exe'

    Write-DynatraceStage 1 5 'Retrieve installer-download token from GCP Secret Manager'
    $dynatraceToken = Get-SecretValue -SecretName $secretName
    if ([string]::IsNullOrWhiteSpace($dynatraceToken)) { throw 'Dynatrace installer token is empty' }
    Write-DynatracePass 'Secret Manager' 'Installer token retrieved without exposing its value'

    # Keep the token in memory only for the authenticated download, then clear
    # both the token and header before validating/executing the installer.
    Write-DynatraceStage 2 5 'Download the latest environment-specific Windows OneAgent installer'
    $downloadUri = "$environmentUrl/api/v1/deployment/installer/agent/windows/default/latest?arch=x86"
    $downloadHeaders = @{ Authorization = "Api-Token $dynatraceToken" }
    Invoke-WebRequest -Headers $downloadHeaders -Uri $downloadUri -OutFile $installer
    $downloadHeaders = $null
    $dynatraceToken = $null

    # Verify publisher trust before executing a freshly downloaded privileged installer.
    $signature = Get-AuthenticodeSignature -FilePath $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Dynatrace') {
        throw "Dynatrace installer signature validation failed: $($signature.Status)"
    }
    Write-DynatracePass 'Installer' 'Microsoft Authenticode signature is valid and signed by Dynatrace'

    Write-DynatraceStage 3 5 "Install OneAgent in $monitoringMode mode"
    $arguments = @(
        '--quiet'
        "--set-monitoring-mode=$monitoringMode"
        "--set-host-group=$hostGroup"
        '--set-host-id-source="mac-addresses;namespace=iis-demo"'
        '--set-host-property=application=iis-demo'
        "--set-host-property=color=$appColor"
        "--set-host-property=version=$appVersion"
        '--set-host-property=ephemeral=true'
        '--set-host-tag=environment=demo'
        '--set-app-log-content-access=false'
        '--set-system-logs-access-enabled=false'
    )
    if ($networkZone) { $arguments += "--set-network-zone=$networkZone" }

    $process = Start-Process -FilePath $installer -ArgumentList ($arguments -join ' ') -Wait -PassThru
    $arguments = $null
    if ($process.ExitCode -notin @(0, 3010)) { throw "OneAgent installer exited with code $($process.ExitCode)" }
    Remove-Item -Path $installer -Force -ErrorAction SilentlyContinue
    Write-DynatracePass 'OneAgent installation' "Installer completed with code $($process.ExitCode)"

    Write-DynatraceStage 4 5 'Restart IIS so full-stack instrumentation can attach'
    & iisreset.exe /restart | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "IIS restart failed with code $LASTEXITCODE" }
    Write-DynatracePass 'IIS restart' 'World Wide Web Publishing Service restarted'

    Write-DynatraceStage 5 5 'Validate OneAgent service and IIS health endpoint'
    # Serial readiness is emitted only after both monitoring and the application
    # are healthy; Cloud Build waits for this marker on every worker before routing.
    $deadline = (Get-Date).AddMinutes(5)
    do {
        $oneAgent = Get-Service | Where-Object { $_.DisplayName -like 'Dynatrace OneAgent*' } | Select-Object -First 1
        if ($oneAgent -and $oneAgent.Status -eq 'Running') { break }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    if (-not $oneAgent -or $oneAgent.Status -ne 'Running') { throw 'Dynatrace OneAgent service did not reach Running state' }

    $health = Invoke-WebRequest -UseBasicParsing -Uri 'http://localhost/health.html'
    if ($health.StatusCode -ne 200 -or $health.Content -notmatch 'healthy') { throw 'IIS health check failed after OneAgent installation' }
    Write-DynatracePass 'Runtime validation' 'OneAgent is running and IIS returned a healthy response'

    Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    Write-Output 'DYNATRACE_READY'
}
catch {
    Write-Output "DYNATRACE_FAILED: $($_.Exception.Message)"
    throw
}
