# Bootstrap only the ephemeral SSH channel used by the image pipeline.
# The pipeline creates a fresh Ed25519 key for each build, passes only its
# public half through instance metadata, and deletes the private key at exit.
# This startup script deliberately installs no app/toolchain content; that is
# provisioned separately by bootstrap.ps1 over the short-lived IAP tunnel.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Get-MetadataValue([string]$Key, [string]$DefaultValue = '') {
    # Optional metadata is allowed to use a safe default; required SSH values
    # are validated by the caller before any account or firewall is configured.
    try {
        $headers = @{ 'Metadata-Flavor' = 'Google' }
        return Invoke-RestMethod -Headers $headers -Uri "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$Key"
    }
    catch {
        return $DefaultValue
    }
}

try {
    # Restrict SSH to the one ephemeral build identity and public key supplied
    # by the orchestrator; no password or reusable key is configured.
    $userName = Get-MetadataValue 'ephemeral-ssh-user' 'gcebuilder'
    $publicKey = Get-MetadataValue 'ephemeral-ssh-public-key' ''
    if ($userName -notmatch '^[a-zA-Z][a-zA-Z0-9._-]{0,31}$') { throw 'Ephemeral SSH user name is invalid' }
    if ($publicKey -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+(?: .*)?$') { throw 'Ephemeral SSH public key is invalid' }

    $capability = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
    if ($capability.State -ne 'Installed') {
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    }

    if (-not (Get-LocalUser -Name $userName -ErrorAction SilentlyContinue)) {
        New-LocalUser -Name $userName -NoPassword -AccountNeverExpires -Description 'Ephemeral Cloud Build SSH account' | Out-Null
    }
    Add-LocalGroupMember -Group 'Administrators' -Member $userName -ErrorAction SilentlyContinue

    # OpenSSH on Windows uses a dedicated authorized-key file and explicit ACLs
    # so only local administrators and SYSTEM can alter the build credential.
    $authorizedKeysPath = Join-Path $env:ProgramData 'ssh\recurring_authorized_keys'
    Set-Content -Path $authorizedKeysPath -Value $publicKey -Encoding ASCII -Force
    icacls.exe $authorizedKeysPath /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null

    $configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
    $configLines = @(
        'Port 22'
        'PubkeyAuthentication yes'
        'Subsystem sftp sftp-server.exe'
        "Match User $userName"
        '    AuthorizedKeysFile __PROGRAMDATA__/ssh/recurring_authorized_keys'
    )
    Set-Content -Path $configPath -Value $configLines -Encoding ASCII -Force

    # The VM is disposable; the orchestrator removes the temporary tunnel rule,
    # local account, key file, and VM during its exit cleanup.
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd
    Write-Output 'SSH_BOOTSTRAP_READY'
}
catch {
    Write-Output "SSH_BOOTSTRAP_FAILED: $($_.Exception.Message)"
    throw
}
