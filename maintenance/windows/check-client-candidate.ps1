#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseDirectory,
    [Parameter(Mandatory)][string]$ScratchDirectory,
    [ValidateSet('Preflight','Apply','Startup')][string]$Mode
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$m = Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'candidate.json') -Raw | ConvertFrom-Json
if ($m.schema -ne 'claudegpt.client_candidate.v1') { throw 'Unexpected candidate.' }
$env:TWEAKCC_CONFIG_DIR = $m.profile
$env:TWEAKCC_CC_INSTALLATION_PATH = $m.candidateBinary
$env:DISABLE_AUTOUPDATER = '1'
$env:TEMP = $ScratchDirectory
$env:TMP = $ScratchDirectory
if ($Mode -eq 'Preflight') {
    & $m.node $m.tool --validate-system-prompts *> (Join-Path $ReleaseDirectory 'prompt-preflight.log')
    $code = $LASTEXITCODE
    @{exitCode=$code;at=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ReleaseDirectory 'prompt-preflight-result.json')
    Write-Output "Prompt preflight exit: $code; inspect prompt-preflight.log"
    exit $code
}
if ($Mode -eq 'Apply') {
    & $m.node (Join-Path $PSScriptRoot 'apply-client-profile.mjs') $ReleaseDirectory *> (Join-Path $ReleaseDirectory 'prompt-apply.log')
    if ($LASTEXITCODE -ne 0) { throw 'Community patch application failed; inspect prompt-apply.log.' }
    $log = Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'prompt-apply.log') -Raw
    if ($log -match '✗|Customizations applied with some failures') { throw 'Community tool reported patch failures despite its exit code.' }
    if ($log -notmatch 'Customizations applied successfully!') { throw 'Missing successful application receipt.' }
    Write-Output 'Community patch application completed; inspect its full applied delta before qualification.'
    return
}
if ($Mode -eq 'Startup') {
    & $m.candidateBinary --version *> (Join-Path $ReleaseDirectory 'patched-version.log')
    if ($LASTEXITCODE -ne 0) { throw 'Patched executable failed its version probe.' }
    $version = (Get-Content -LiteralPath (Join-Path $ReleaseDirectory 'patched-version.log') -Raw).Trim()
    if ($version -ne "$($m.version) (Claude Code)") { throw 'Patched version mismatch.' }
    & $m.candidateBinary --help *> (Join-Path $ReleaseDirectory 'patched-help.log')
    if ($LASTEXITCODE -ne 0) { throw 'Patched CLI help failed.' }
    Write-Output 'Patched native executable version and CLI startup passed.'
}
