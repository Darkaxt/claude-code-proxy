#requires -Version 7.2
param([Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
if (Test-Path -LiteralPath $FixtureRoot) { throw 'new_fixture_required' }
[void][IO.Directory]::CreateDirectory($FixtureRoot)
$scratch=Join-Path $FixtureRoot 'runtime scratch'
[void][IO.Directory]::CreateDirectory($scratch)
$skill=Join-Path $FixtureRoot 'SKILL.md'
Set-Content -LiteralPath $skill -Value 'Fictional fixture skill. No inference.'
$installed=Join-Path $FixtureRoot 'start-hidden.vbs'
$supervisor=Join-Path $FixtureRoot 'supervise-proxy.ps1'
$shortcutPath=Join-Path $FixtureRoot 'startup.lnk'
$snapshot=Join-Path $FixtureRoot 'environment.json'
@'
$ErrorActionPreference='Stop'
@{ TEMP=$env:TEMP; TMP=$env:TMP; CCP_APPROACH_RECOVERY_SKILL_PATH=$env:CCP_APPROACH_RECOVERY_SKILL_PATH; CCP_LOG_STDERR=$env:CCP_LOG_STDERR; processId=$PID } | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot 'environment.json')
exit 7
'@ | Set-Content -LiteralPath $supervisor
# Reproduce the original sign-in launcher, with no environment setup.
@'
Set s=CreateObject("WScript.Shell")
Set f=CreateObject("Scripting.FileSystemObject")
WScript.Quit s.Run("powershell.exe -NoProfile -NonInteractive -File """ & f.BuildPath(f.GetParentFolderName(WScript.ScriptFullName),"supervise-proxy.ps1") & """",0,True)
'@ | Set-Content -LiteralPath $installed
$shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
$shortcut.TargetPath="$env:SystemRoot\System32\wscript.exe"
$shortcut.Arguments='//B //Nologo "'+$installed+'"'
$shortcut.WorkingDirectory=$FixtureRoot
$shortcut.Save()
function Hash([string]$Path) { (Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant() }
$m=@{schema='claudegpt.fork_startup.v1';launcherSource=(Join-Path $PSScriptRoot 'start-fork-hidden.vbs');
    installedLauncher=$installed;startupShortcut=$shortcutPath;persistentScratch=$scratch;recoverySkillPath=$skill;
    rollbackDirectory=(Join-Path $FixtureRoot 'rollback');receiptPath=(Join-Path $FixtureRoot 'receipt.json');
    expectedLauncherSha256=(Hash $installed);expectedShortcutSha256=(Hash $shortcutPath);expectedArguments=$shortcut.Arguments}
$m.launcherSha256=Hash $m.launcherSource
$manifest=Join-Path $FixtureRoot 'manifest.json'
$m | ConvertTo-Json | Set-Content -LiteralPath $manifest
function Run-Launcher([string[]]$Arguments=@()) {
    $info=[Diagnostics.ProcessStartInfo]::new("$env:SystemRoot\System32\wscript.exe")
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    foreach ($arg in @('//B','//Nologo',$installed)+$Arguments) { [void]$info.ArgumentList.Add($arg) }
    $info.Environment['TEMP']=$FixtureRoot; $info.Environment['TMP']=$FixtureRoot
    [void]$info.Environment.Remove('CCP_APPROACH_RECOVERY_SKILL_PATH')
    [void]$info.Environment.Remove('CCP_LOG_STDERR')
    $process=[Diagnostics.Process]::Start($info)
    try { $process.WaitForExit(); return $process.ExitCode } finally { $process.Dispose() }
}
$parentTemp=$env:TEMP; $parentSkill=$env:CCP_APPROACH_RECOVERY_SKILL_PATH
if ((Run-Launcher) -ne 7) { throw 'baseline_probe_exit' }
$before=Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
if ($before.TEMP -eq $scratch -or $before.CCP_APPROACH_RECOVERY_SKILL_PATH) { throw 'baseline_did_not_reproduce' }
$baselineSnapshotHash=Hash $snapshot
& (Join-Path $PSScriptRoot 'install-fork-startup.ps1') -ManifestPath $manifest | Out-Null
if ((Hash $installed) -ne $m.expectedLauncherSha256 -or (Hash $shortcutPath) -ne $m.expectedShortcutSha256) { throw 'validation_mutated' }
$bad=$m.Clone(); $bad.expectedLauncherSha256='0'*64
$badPath=Join-Path $FixtureRoot 'bad.json'; $bad | ConvertTo-Json | Set-Content $badPath
$refused=$false
try { & (Join-Path $PSScriptRoot 'install-fork-startup.ps1') -ManifestPath $badPath -Apply | Out-Null } catch { $refused=$_.Exception.Message -like 'startup_input_changed:*' }
if (-not $refused -or (Test-Path $m.rollbackDirectory)) { throw 'changed_input_not_refused' }
& (Join-Path $PSScriptRoot 'install-fork-startup.ps1') -ManifestPath $manifest -Apply | Out-Null
if ((Run-Launcher) -ne 64 -or (Run-Launcher -Arguments @('C:\missing',$skill)) -ne 64 -or
    (Run-Launcher -Arguments @($scratch,(Join-Path $FixtureRoot 'missing.md'))) -ne 66 -or (Hash $snapshot) -ne $baselineSnapshotHash) { throw 'invalid_input_launched' }
if ((Run-Launcher -Arguments @($scratch,$skill)) -ne 7) { throw 'supervisor_exit_not_propagated' }
$after=Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
if ($after.TEMP -ne $scratch -or $after.TMP -ne $scratch -or $after.CCP_APPROACH_RECOVERY_SKILL_PATH -ne $skill -or $after.CCP_LOG_STDERR -ne '1') { throw 'environment_not_delivered' }
if ($env:TEMP -ne $parentTemp -or $env:CCP_APPROACH_RECOVERY_SKILL_PATH -ne $parentSkill) { throw 'parent_environment_changed' }
& (Join-Path $PSScriptRoot 'install-fork-startup.ps1') -ManifestPath $manifest -Restore | Out-Null
if ((Hash $installed) -ne $m.expectedLauncherSha256 -or (Hash $shortcutPath) -ne $m.expectedShortcutSha256) { throw 'restore_not_exact' }
if ((Run-Launcher) -ne 7) { throw 'restored_launcher_failed' }
@{ok=$true;baseline_loss_reproduced=$true;environment_delivered=$true;validation_non_mutating=$true;
    changed_input_refused=$true;invalid_input_refused=$true;supervisor_exit_observed=$true;exit_code_propagated=$true;
    exact_restore_verified=$true;parent_environment_unchanged=$true;realInferenceRequests=0} | ConvertTo-Json
