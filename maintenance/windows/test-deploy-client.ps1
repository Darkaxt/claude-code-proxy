#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ProductionManifest,[Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
function Hash($Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
function Save($Value,$Path) { $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM }
if(Test-Path -LiteralPath $FixtureRoot) {throw 'Fixture root already exists.'}
$p=Get-Content -LiteralPath $ProductionManifest -Raw | ConvertFrom-Json -AsHashtable
$deployer=Join-Path (Split-Path $p.probeScript -Parent) 'deploy-client.ps1'
New-Item -ItemType Directory -Path $FixtureRoot | Out-Null
$results=@()
foreach($scenario in @('success-and-restore','post-activation-failure')) {
    $root=Join-Path $FixtureRoot $scenario
    New-Item -ItemType Directory -Path $root | Out-Null
    $m=Get-Content -LiteralPath $ProductionManifest -Raw | ConvertFrom-Json -AsHashtable
    $m.installedBinary=Join-Path $root 'claude.exe'
    Copy-Item -LiteralPath $p.installedBinary -Destination $m.installedBinary
    $m.settingsPath=Join-Path $root 'settings.json'
    Save @{model='fixture-model';env=@{FIXTURE_MARKER='preserve'}} $m.settingsPath
    $m.expectedSettingsSha256=Hash $m.settingsPath
    $m.updatedSettingsPath=Join-Path $root 'updated-settings.json'
    Save @{model='fixture-model';env=@{FIXTURE_MARKER='preserve';DISABLE_AUTOUPDATER='1'}} $m.updatedSettingsPath
    $m.updatedSettingsSha256=Hash $m.updatedSettingsPath
    $m.expectedInstalledSha256=Hash $m.installedBinary
    $m.protectedFiles=@()
    $m.rollbackDirectory=Join-Path $root 'rollback'
    $m.receiptPath=Join-Path $root 'receipt.json'
    $m.probeScript=Join-Path $root 'fictional-probe.mjs'
    $m.probeDirectory=Join-Path $root 'probe'
    $m.probeLog=Join-Path $root 'probe.log'
    $exitCode=if($scenario -eq 'post-activation-failure'){7}else{0}
    "// Fictional fixture: no inference or external I/O.`nprocess.exit($exitCode);" | Set-Content -LiteralPath $m.probeScript -Encoding utf8NoBOM
    $m.probeScriptSha256=Hash $m.probeScript
    $manifest=Join-Path $root 'manifest.json'
    Save $m $manifest
    & pwsh.exe -NoProfile -NonInteractive -File $deployer -ManifestPath $manifest *> (Join-Path $root 'validate.log')
    if($LASTEXITCODE -ne 0 -or (Hash $m.installedBinary) -ne $m.expectedInstalledSha256) {throw "Read-only validation failed: $root"}
    & pwsh.exe -NoProfile -NonInteractive -File $deployer -ManifestPath $manifest -Mode Apply *> (Join-Path $root 'apply.log')
    $appliedExit=$LASTEXITCODE
    if($scenario -eq 'success-and-restore') {
        if($appliedExit -ne 0) {throw "Fixture activation failed: $root"}
        & pwsh.exe -NoProfile -NonInteractive -File $deployer -ManifestPath $manifest -Mode Verify *> (Join-Path $root 'verify.log')
        if($LASTEXITCODE -ne 0) {throw 'Fixture installed verification failed.'}
        & pwsh.exe -NoProfile -NonInteractive -File $deployer -ManifestPath $manifest -Mode Restore *> (Join-Path $root 'restore.log')
        if($LASTEXITCODE -ne 0) {throw 'Fixture explicit restore failed.'}
    } else {
        $receipt=Get-Content -LiteralPath $m.receiptPath -Raw | ConvertFrom-Json
        if($appliedExit -eq 0 -or $receipt.state -ne 'rolled_back_verified') {throw 'Fixture failed to demonstrate automatic rollback.'}
    }
    if((Hash $m.installedBinary) -ne $m.expectedInstalledSha256 -or (Hash $m.settingsPath) -ne $m.expectedSettingsSha256) {throw 'Fixture restoration hashes differ.'}
    $results+=@{scenario=$scenario;passed=$true;restorationHashesVerified=$true;liveInstallationChanged=$false;realInference=$false}
}
$results | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $FixtureRoot 'results.json')
$results | ConvertTo-Json -Depth 8
