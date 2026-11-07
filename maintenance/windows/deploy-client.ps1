#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [ValidateSet('Validate','Apply','Verify','Restore')][string]$Mode = 'Validate'
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$m = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -AsHashtable
if ($m.schema -ne 'claudegpt.client_deployment.v1') { throw 'Unexpected manifest schema.' }
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Assert-Hash([string]$Path, [string]$Expected) {
    if ((Hash $Path) -ne $Expected) { throw "Changed file: $Path" }
}
function Assert-Idle {
    $clients = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'claude.exe' -or
        ($_.Name -eq 'node.exe' -and $_.CommandLine -match '(?:claude-code[\\/].*cli\.js|[\\/]claude[\\/]cli\.js)')
    })
    if ($clients.Count) { throw "Running Claude clients prevent activation: $($clients.ProcessId -join ',')" }
}
function Assert-Protected {
    foreach ($f in $m.protectedFiles) { Assert-Hash $f.path $f.sha256 }
}
function Assert-Settings([string]$ExpectedHash) { Assert-Hash $m.settingsPath $ExpectedHash }
function Assert-SettingsChange {
    $expected = Get-Content -LiteralPath $m.settingsPath -Raw | ConvertFrom-Json -AsHashtable
    if (-not $expected.ContainsKey('env')) { $expected.env = @{} }
    $expected.env.DISABLE_AUTOUPDATER = '1'
    $proposed = Get-Content -LiteralPath $m.updatedSettingsPath -Raw | ConvertFrom-Json -AsHashtable
    $expectedNode=[System.Text.Json.Nodes.JsonNode]::Parse(($expected | ConvertTo-Json -Depth 100 -Compress))
    $proposedNode=[System.Text.Json.Nodes.JsonNode]::Parse(($proposed | ConvertTo-Json -Depth 100 -Compress))
    if (-not [System.Text.Json.Nodes.JsonNode]::DeepEquals($expectedNode,$proposedNode)) {
        throw 'Settings change exceeds the one authorized background-updater setting.'
    }
}
function Replace-File([string]$Source, [string]$Destination, [string]$ExpectedHash) {
    $pending = "$Destination.claudegpt-new"
    if (Test-Path -LiteralPath $pending) { throw "Unfinished activation staging file: $pending" }
    Copy-Item -LiteralPath $Source -Destination $pending
    Assert-Hash $pending (Hash $Source)
    Assert-Hash $Destination $ExpectedHash
    Assert-Idle
    [IO.File]::Replace($pending, $Destination, [NullString]::Value)
    Assert-Hash $Destination (Hash $Source)
}
function Version([string]$Path) {
    $out = & $Path --version
    if ($LASTEXITCODE -ne 0) { throw 'CLI version probe failed.' }
    ($out -join "`n").Trim()
}
function Write-Receipt([string]$State, $Extra) {
    $record = @{schema='claudegpt.client_activation.v1';state=$State;at=[DateTime]::UtcNow.ToString('o');manifest=$ManifestPath;version=$m.version;candidateSha256=$m.candidateSha256;extra=$Extra}
    $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $m.receiptPath -Encoding utf8NoBOM
}
function Assert-Installed {
    Assert-Hash $m.installedBinary $m.candidateSha256
    Assert-Settings $m.updatedSettingsSha256
    Assert-Protected
    if ((Version $m.installedBinary) -ne "$($m.version) (Claude Code)") { throw 'Installed version mismatch.' }
}
Assert-Hash $m.candidateBinary $m.candidateSha256
Assert-Hash $m.verificationPath $m.verificationSha256
Assert-Hash $m.probeScript $m.probeScriptSha256
$v = Get-Content -LiteralPath $m.verificationPath -Raw | ConvertFrom-Json
if (-not $v.qualified -or $v.candidateSha256 -ne $m.candidateSha256) { throw 'Candidate is not qualified.' }
if ($Mode -eq 'Verify') {
    Assert-Installed
    Write-Output 'Installed client hash, version, settings and protected files verified.'
    return
}
if ($Mode -eq 'Restore') {
    Assert-Idle
    Assert-Protected
    Assert-Hash $m.installedBinary $m.candidateSha256
    Assert-Settings $m.updatedSettingsSha256
    Assert-Hash (Join-Path $m.rollbackDirectory 'claude.exe') $m.expectedInstalledSha256
    Assert-Hash (Join-Path $m.rollbackDirectory 'settings.json') $m.expectedSettingsSha256
    Replace-File (Join-Path $m.rollbackDirectory 'claude.exe') $m.installedBinary $m.candidateSha256
    Replace-File (Join-Path $m.rollbackDirectory 'settings.json') $m.settingsPath $m.updatedSettingsSha256
    Assert-Hash $m.installedBinary $m.expectedInstalledSha256
    Assert-Settings $m.expectedSettingsSha256
    $restoredVersion = Version $m.installedBinary
    Write-Receipt 'restored' @{version=$restoredVersion;sha256=(Hash $m.installedBinary)}
    Write-Output "Restored $restoredVersion"
    return
}
Assert-Idle
Assert-Protected
Assert-Hash $m.installedBinary $m.expectedInstalledSha256
Assert-Settings $m.expectedSettingsSha256
Assert-Hash $m.updatedSettingsPath $m.updatedSettingsSha256
Assert-SettingsChange
if ((Version $m.candidateBinary) -ne "$($m.version) (Claude Code)") { throw 'Candidate version mismatch.' }
if ($Mode -eq 'Validate') { Write-Output 'Candidate and activation inputs verified; no live files changed.'; return }
$mutex = [Threading.Mutex]::new($false, 'Local\ClaudeGPTClientMaintenance')
$held = $false
try {
    try { $held = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { throw 'Another managed client activation is running.' }
    Assert-Idle
    Assert-Protected
    Assert-Hash $m.installedBinary $m.expectedInstalledSha256
    Assert-Settings $m.expectedSettingsSha256
    if (Test-Path -LiteralPath $m.rollbackDirectory) { throw 'Rollback destination exists; inspect earlier activation.' }
    New-Item -ItemType Directory -Path $m.rollbackDirectory | Out-Null
    Copy-Item -LiteralPath $m.installedBinary -Destination (Join-Path $m.rollbackDirectory 'claude.exe')
    Copy-Item -LiteralPath $m.settingsPath -Destination (Join-Path $m.rollbackDirectory 'settings.json')
    Assert-Hash (Join-Path $m.rollbackDirectory 'claude.exe') $m.expectedInstalledSha256
    Assert-Hash (Join-Path $m.rollbackDirectory 'settings.json') $m.expectedSettingsSha256
    Write-Receipt 'rollback_saved' @{}
    $binaryWritten = $false
    $settingsWritten = $false
    try {
        Assert-Idle
        # Stage next to each destination, then replace atomically on that volume.
        Replace-File $m.candidateBinary $m.installedBinary $m.expectedInstalledSha256
        $binaryWritten = $true
        Replace-File $m.updatedSettingsPath $m.settingsPath $m.expectedSettingsSha256
        $settingsWritten = $true
        Assert-Installed
        & $m.nodePath $m.probeScript $m.installedBinary $m.probeDirectory *> $m.probeLog
        if ($LASTEXITCODE -ne 0) { throw 'Installed client request probe failed; inspect the retained probe log.' }
        Assert-Installed
        Write-Receipt 'activated_verified' @{installedSha256=(Hash $m.installedBinary);settingsSha256=(Hash $m.settingsPath)}
        Write-Output 'Activated and independently verified the managed client.'
    } catch {
        $failure = $_.Exception.Message
        # Restore only files this transaction may have written; preserve unrelated edits.
        $currentBinaryHash = Hash $m.installedBinary
        $currentSettingsHash = Hash $m.settingsPath
        if ($currentBinaryHash -notin @($m.expectedInstalledSha256,$m.candidateSha256) -or
            $currentSettingsHash -notin @($m.expectedSettingsSha256,$m.updatedSettingsSha256)) {
            Write-Receipt 'recovery_incomplete' @{failure=$failure;reason='Unexpected concurrent file change; do not overwrite.'}
            throw 'Unexpected concurrent file change; recovery requires review.'
        }
        if ($currentBinaryHash -eq $m.candidateSha256) {
            Replace-File (Join-Path $m.rollbackDirectory 'claude.exe') $m.installedBinary $currentBinaryHash
        }
        if ($currentSettingsHash -eq $m.updatedSettingsSha256) { Replace-File (Join-Path $m.rollbackDirectory 'settings.json') $m.settingsPath $currentSettingsHash }
        Assert-Hash $m.installedBinary $m.expectedInstalledSha256
        Assert-Settings $m.expectedSettingsSha256
        Assert-Protected
        Write-Receipt 'rolled_back_verified' @{failure=$failure;version=(Version $m.installedBinary)}
        throw "Activation failed; previous state restored and verified: $failure"
    }
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
