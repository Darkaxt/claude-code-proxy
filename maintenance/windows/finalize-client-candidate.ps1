#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseDirectory,
    [Parameter(Mandatory)][string]$ProbeReceipt,
    [Parameter(Mandatory)][string]$InstallBinary,
    [Parameter(Mandatory)][string]$SettingsPath,
    [Parameter(Mandatory)][string]$StateDirectory,
    [Parameter(Mandatory)][string[]]$ProtectedPaths
)
$ErrorActionPreference='Stop'
function Hash($Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Save($Value,$Path) { $Value | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM }
$m=Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'candidate.json') -Raw | ConvertFrom-Json -AsHashtable
$payload=Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'payload-inspection.json') -Raw | ConvertFrom-Json -AsHashtable
if (@($payload.checks.Values | Where-Object {$_ -ne $true}).Count) { throw 'Native payload inspection failed.' }
$probe=Get-Content -LiteralPath $ProbeReceipt -Raw | ConvertFrom-Json
if (-not $probe.passed -or -not $probe.childExited -or $probe.requestRetries -ne 0) { throw 'Candidate real-request verification did not pass.' }
$version=(Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'patched-version.log') -Raw).Trim()
if ($version -ne "$($m.version) (Claude Code)") { throw 'Startup version verification mismatch.' }
$apply=Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'prompt-apply.log') -Raw
$cleanupOnly=$apply -match 'EBUSY: resource busy or locked, unlink' -and $apply -match 'tweakcc-native-' -and $apply -notmatch 'SyntaxError|patch\(es\) failed|Cannot update'
$normalApply=$apply -match 'Customizations applied successfully!' -and $apply -notmatch '✗|Customizations applied with some failures'
if (-not ($normalApply -or $cleanupOnly)) { throw 'Unresolved community patch application failure.' }
$applyReadback=Get-Content -LiteralPath (Join-Path $m.profile 'native-claudejs-patched.js') -Raw
if (-not $applyReadback -or -not $payload.checks.matchesExactCommunityPatchedPayload) { throw 'Missing exact payload readback.' }
Copy-Item -LiteralPath $ProbeReceipt -Destination (Join-Path $ReleaseDirectory 'candidate-probe.json')
$binaryHash=Hash $m.candidateBinary
$authorizationProbe=Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'authorization-probe.json') -Raw | ConvertFrom-Json -AsHashtable
if(-not $authorizationProbe.passed -or -not $authorizationProbe.childExited -or -not $authorizationProbe.nativeBypassPermissionsFlag -or $authorizationProbe.requestRetries -ne 0 -or $authorizationProbe.candidateSha256 -ne $binaryHash){throw 'Authorization behavior probe is missing, failed, lacks native bypass mode or belongs to other bytes.'}
$verification=@{
    schema='claudegpt.client_verification.v1';qualified=$true;candidateSha256=$binaryHash
    version=$m.version;tweakVersion=$m.tweakVersion;promptCommit=$m.promptCommit
    startupPassed=$true;payloadChecks=$payload.checks;realProxyRequestPassed=$true
    authorizationAdaptation=(Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'authorization-adaptation.json') -Raw | ConvertFrom-Json -AsHashtable)
    authorizationBehavior=$authorizationProbe
    communityExitClassification=$(if($cleanupOnly){'postwrite-temporary-cleanup-error'}else{'normal-success'})
    cleanupFailureDisposition='Owned patcher processes exited; exact output readback and real request passed. See the run cleanup receipt for temporary-file disposition.'
    at=[DateTime]::UtcNow.ToString('o')
    limits=@('Cross-platform/nonunique catalogue sites excluded; two obsolete overlapping inline loop files retained outside the active profile.','Actual reversing behavior and long-session compaction cadence are not certified by the benign probe.')
}
Save $verification (Join-Path $ReleaseDirectory 'verification.json')
$m.qualified=$true
$m.candidateSha256=$binaryHash
Save $m (Join-Path $ReleaseDirectory 'candidate.json')
$bundle=Join-Path $ReleaseDirectory 'maintenance'
New-Item -ItemType Directory -Path $bundle -Force | Out-Null
foreach($file in @('prepare-client.ps1','check-client-candidate.ps1','preflight-client-profile.mjs','apply-client-profile.mjs','adapt-client-authorization.mjs','test-adapt-client-authorization.mjs','exclude-client-pristine-literals.mjs','test-client-pristine-literals.mjs','test-client-preflight-review.mjs','inspect-client-payload.mjs','review-client-preflight.mjs','probe-client.mjs','probe-client-authorization.mjs','deploy-client.ps1','finalize-client-candidate.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $bundle $file)
}
$overrideBundle=Join-Path $bundle 'client-overrides'
foreach($file in @('exclude-client-loop-overlaps.mjs','test-client-loop-overlaps.mjs')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $bundle $file)
}
New-Item -ItemType Directory -Path $overrideBundle -Force | Out-Null
foreach($override in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'client-overrides') -Filter '*.md' -File){Copy-Item -LiteralPath $override.FullName -Destination (Join-Path $overrideBundle $override.Name)}
$settings=Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json -AsHashtable
$updaterAlreadyDisabled=$settings.ContainsKey('env') -and $settings.env.DISABLE_AUTOUPDATER -eq '1'
if(-not $settings.ContainsKey('env')) {$settings.env=@{}}
$settings.env.DISABLE_AUTOUPDATER='1'
$updated=Join-Path $ReleaseDirectory 'settings-managed.json'
if($updaterAlreadyDisabled){Copy-Item -LiteralPath $SettingsPath -Destination $updated}else{Save $settings $updated}
$protected=@()
foreach($p in $ProtectedPaths) {
    if(Test-Path -LiteralPath $p -PathType Leaf) {$protected+=@{path=$p;sha256=(Hash $p)}}
}
$manifest=@{
    schema='claudegpt.client_deployment.v1';version=$m.version
    candidateBinary=$m.candidateBinary;candidateSha256=$binaryHash
    verificationPath=(Join-Path $ReleaseDirectory 'verification.json');verificationSha256=(Hash (Join-Path $ReleaseDirectory 'verification.json'))
    installedBinary=$InstallBinary;expectedInstalledSha256=(Hash $InstallBinary)
    settingsPath=$SettingsPath;expectedSettingsSha256=(Hash $SettingsPath)
    updatedSettingsPath=$updated;updatedSettingsSha256=(Hash $updated);protectedFiles=$protected
    rollbackDirectory=(Join-Path $StateDirectory 'rollback')
    receiptPath=(Join-Path $StateDirectory 'activation.json')
    nodePath=$m.node;probeScript=(Join-Path $bundle 'probe-client.mjs');probeScriptSha256=(Hash (Join-Path $bundle 'probe-client.mjs'))
    probeDirectory=(Join-Path $StateDirectory 'probe-installed');probeLog=(Join-Path $StateDirectory 'probe-installed.log')
}
Save $manifest (Join-Path $StateDirectory 'deployment.json')
Write-Output "Qualified $($m.version); SHA256 $binaryHash"
