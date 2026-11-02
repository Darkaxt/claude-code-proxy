#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReleaseDirectory,
    [Parameter(Mandatory)][string]$ScratchDirectory,
    [Parameter(Mandatory)][string]$PromptRepository,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$PromptCommit,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$ClaudeVersion,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$TweakVersion
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
function Write-Json($Value, $Path) {
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}
function Invoke-Logged([string]$Program, [string[]]$Arguments, [string]$Log) {
    & $Program @Arguments *> $Log
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE); inspect $Log" }
}
if (Test-Path -LiteralPath $ReleaseDirectory) { throw 'Release directory already exists; inspect it before another preparation.' }
if ($PromptRepository -ne 'https://github.com/skrabe/lobotomized-claude-code.git') { throw 'Unexpected prompt source.' }
New-Item -ItemType Directory -Path $ReleaseDirectory, $ScratchDirectory -Force | Out-Null
$savedEnvironment = @{}
foreach ($name in @('TEMP','TMP','npm_config_cache','TWEAKCC_CONFIG_DIR','TWEAKCC_CC_INSTALLATION_PATH','DISABLE_AUTOUPDATER')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    $env:TEMP = $ScratchDirectory
    $env:TMP = $ScratchDirectory
    $env:npm_config_cache = Join-Path $ScratchDirectory 'npm-cache'
    $env:DISABLE_AUTOUPDATER = '1'
    $runtime = Join-Path $ReleaseDirectory 'runtime'
    New-Item -ItemType Directory -Path $runtime | Out-Null
    $npm = (Get-Command npm.cmd -ErrorAction Stop).Source
    $node = (Get-Command node.exe -ErrorAction Stop).Source
    Invoke-Logged $npm @('install','--prefix',$runtime,'--ignore-scripts','--no-audit','--no-fund','--save-exact',"tweakcc-fixed@$TweakVersion","@anthropic-ai/claude-code-win32-x64@$ClaudeVersion") (Join-Path $ReleaseDirectory 'npm-install.log')
    $toolPackage = Join-Path $runtime 'node_modules/tweakcc-fixed/package.json'
    $toolInfo = Get-Content -LiteralPath $toolPackage -Raw | ConvertFrom-Json
    if ($toolInfo.version -ne $TweakVersion -or $toolInfo.supportedClaudeCode -ne $ClaudeVersion) { throw 'Package support/version mismatch.' }
    $platformRoot = Join-Path $runtime 'node_modules/@anthropic-ai/claude-code-win32-x64'
    $vendor = @(Get-ChildItem -LiteralPath $platformRoot -Recurse -Filter claude.exe -File)
    if ($vendor.Count -ne 1) { throw 'Expected exactly one vendor executable.' }
    $vendorHash = (Get-FileHash -LiteralPath $vendor[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $signature = Get-AuthenticodeSignature -LiteralPath $vendor[0].FullName
    Write-Json @{status=[string]$signature.Status; subject=$signature.SignerCertificate.Subject; sha256=$vendorHash} (Join-Path $ReleaseDirectory 'vendor-signature.json')
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Anthropic') { throw 'Vendor signature did not verify as Anthropic.' }
    $candidate = Join-Path $ReleaseDirectory 'claude.exe'
    Copy-Item -LiteralPath $vendor[0].FullName -Destination $candidate
    Invoke-Logged $candidate @('--version') (Join-Path $ReleaseDirectory 'vendor-version.log')
    $source = Join-Path $ReleaseDirectory 'prompt-source'
    Invoke-Logged 'git.exe' @('clone','--no-checkout',$PromptRepository,$source) (Join-Path $ReleaseDirectory 'prompt-clone.log')
    Invoke-Logged 'git.exe' @('-C',$source,'checkout','--detach',$PromptCommit) (Join-Path $ReleaseDirectory 'prompt-checkout.log')
    $actualCommit = (& git.exe -C $source rev-parse HEAD).Trim()
    if ($actualCommit -ne $PromptCommit) { throw 'Prompt source identity mismatch.' }
    $profile = Join-Path $ReleaseDirectory 'profile'
    New-Item -ItemType Directory -Path $profile | Out-Null
    # Native copying avoids the measured per-file PowerShell overhead on this catalogue.
    foreach ($pair in @(@('system-prompts-lcc','system-prompts'),@('system-reminders','system-reminders'))) {
        $PSNativeCommandUseErrorActionPreference = $false
        & robocopy.exe (Join-Path $source $pair[0]) (Join-Path $profile $pair[1]) /E /MT:4 /R:0 /W:0 /NFL /NDL /NJH /NJS *> (Join-Path $ReleaseDirectory "$($pair[1])-copy.log")
        if ($LASTEXITCODE -gt 7) { throw "Profile copy failed: $($pair[0]) ($LASTEXITCODE)" }
        $PSNativeCommandUseErrorActionPreference = $true
    }
    $env:TWEAKCC_CONFIG_DIR = $profile
    $env:TWEAKCC_CC_INSTALLATION_PATH = $candidate
    # The explicit filter excludes unrelated default patches and experimental features.
    $patches = 'all-profile-prompt-ids,fix-summarize-from-here,fix-rewind-summary-header,strip-empty-system-reminders,read-default-lines'
    Write-Json @{ccVersion=$ClaudeVersion;ccInstallationPath=$candidate;lastModified=[DateTime]::UtcNow.ToString('o');changesApplied=$false} (Join-Path $profile 'config.json')
    $tool = Join-Path $runtime 'node_modules/tweakcc-fixed/dist/index.mjs'
    Invoke-Logged $node @($tool,'--help') (Join-Path $ReleaseDirectory 'tweak-help.log')
    Invoke-Logged $node @($tool,'--fetch-system-prompts',$ClaudeVersion) (Join-Path $ReleaseDirectory 'prompt-fetch.log')
    # Do not apply yet: retain source/profile for instruction and delta review first.
    $inputs = @{
        schema='claudegpt.client_candidate.v1'; version=$ClaudeVersion; tweakVersion=$TweakVersion
        promptCommit=$PromptCommit; promptRepository=$PromptRepository; vendorSha256=$vendorHash
        candidateBinary=$candidate; profile=$profile; tool=$tool; node=$node; patches=$patches
        packageLockSha256=(Get-FileHash -LiteralPath (Join-Path $runtime 'package-lock.json')).Hash.ToLowerInvariant()
        preparedAt=[DateTime]::UtcNow.ToString('o'); qualified=$false
    }
    Write-Json $inputs (Join-Path $ReleaseDirectory 'candidate.json')
    Write-Output "Prepared pinned inputs: $ReleaseDirectory"
} finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process') }
}
