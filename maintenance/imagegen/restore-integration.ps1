#Requires -Version 7.4
param([Parameter(Mandatory)][string]$RecoveryPackage,[switch]$ValidateOnly)
$ErrorActionPreference='Stop'
$r=Get-Content -LiteralPath $RecoveryPackage -Raw|ConvertFrom-Json -AsHashtable
function Check($p,$h){if((Get-FileHash -LiteralPath $p).Hash.ToLowerInvariant() -ne $h){throw "Recovery input changed: $p"}}
Check $r.runtimeManifest $r.runtimeManifestSha256
Check $r.originalManifest $r.originalManifestSha256
Check $r.helper $r.helperSha256
Check $r.lifecycle $r.lifecycleSha256
Check $r.clientBinary $r.clientSha256
$installed=Get-Content -LiteralPath $r.clientInstallReceipt -Raw|ConvertFrom-Json -AsHashtable
$current=Get-Content 'C:\Users\darka\.claude.json' -Raw|ConvertFrom-Json -AsHashtable
$entryA=[System.Text.Json.Nodes.JsonNode]::Parse(($current.mcpServers.claudegpt_imagegen|ConvertTo-Json -Depth 15 -Compress))
$entryB=[System.Text.Json.Nodes.JsonNode]::Parse(($installed.entry|ConvertTo-Json -Depth 15 -Compress))
if(-not [System.Text.Json.Nodes.JsonNode]::DeepEquals($entryA,$entryB)){throw 'Managed MCP entry changed'}
Check $installed.installedSkill $installed.installedSkillSha256
$disabled=Join-Path $r.originalState 'config-rollback\disabled-SKILL.md'
if(Test-Path $disabled){throw 'Previous deactivation record exists'}
$mode=if($ValidateOnly){'ValidateRestore'}else{'Restore'}
& $r.helper -Manifest $r.originalManifest -RecoveryRuntimeManifest $r.runtimeManifest -LifecycleScript $r.lifecycle -Mode $mode
if($ValidateOnly){return}
& $r.clientBinary mcp remove claudegpt_imagegen --scope user
if($LASTEXITCODE){throw 'Native MCP removal failed after configuration restoration; inspect remaining registration'}
Move-Item -LiteralPath $installed.installedSkill -Destination $disabled
@{status='restored';at=[DateTime]::UtcNow.ToString('o');recoveryPackage=$RecoveryPackage;proxyConfigAndServiceRestored=$true;managedMcpEntryRemoved=$true;managedSkillDisabled=$true;disabledSkill=$disabled}|ConvertTo-Json|Set-Content (Join-Path $r.originalState 'restore-receipt.json') -Encoding utf8NoBOM
