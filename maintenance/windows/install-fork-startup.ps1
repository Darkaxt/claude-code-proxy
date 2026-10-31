#requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ManifestPath,[switch]$Apply,[switch]$Restore)
$ErrorActionPreference='Stop'
if ($Apply -and $Restore) { throw 'choose_apply_or_restore' }
$m=Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ($m.schema -ne 'claudegpt.fork_startup.v1') { throw 'startup_manifest_schema' }
foreach ($key in @('launcherSource','installedLauncher','startupShortcut','persistentScratch','recoverySkillPath','rollbackDirectory','receiptPath')) {
    if (-not [IO.Path]::IsPathFullyQualified($m.$key) -or $m.$key.Contains('"')) { throw "absolute_path_required:$key" }
}
function Hash([string]$Path) {
    $file=Get-Item -LiteralPath $Path
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'regular_file_required' }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Assert-Hash([string]$Path,[string]$Expected) {
    if ($Expected -notmatch '^[a-f0-9]{64}$' -or (Hash $Path) -ne $Expected) { throw "startup_input_changed:$Path" }
}
function Assert-Shortcut([string]$Arguments) {
    $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($m.startupShortcut)
    if ($shortcut.TargetPath -ne "$env:SystemRoot\System32\wscript.exe" -or $shortcut.Arguments -ne $Arguments -or
        $shortcut.WorkingDirectory -ne (Split-Path -Parent $m.installedLauncher)) { throw 'startup_shortcut_mismatch' }
}
function Assert-Baseline {
    Assert-Hash $m.installedLauncher $m.expectedLauncherSha256
    Assert-Hash $m.startupShortcut $m.expectedShortcutSha256
    Assert-Shortcut $m.expectedArguments
}
$newArguments='//B //Nologo "'+$m.installedLauncher+'" "'+$m.persistentScratch+'" "'+$m.recoverySkillPath+'"'
if ($m.persistentScratch -notmatch '^[DE]:\\' -or -not (Test-Path -LiteralPath $m.persistentScratch -PathType Container) -or
    -not (Test-Path -LiteralPath $m.recoverySkillPath -PathType Leaf)) { throw 'startup_environment_missing' }
Assert-Hash $m.launcherSource $m.launcherSha256
if (-not $Restore) { Assert-Baseline }
if (-not $Apply -and -not $Restore) { [pscustomobject]@{status='validated';activated=$false}; return }
$mutex=[Threading.Mutex]::new($false,'Local\ClaudeCodeProxyUpdater-mutex')
$owns=$false
try {
    try { $owns=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owns=$true }
    if (-not $owns) { throw 'updater_mutex_busy' }
    $rollbackLauncher=Join-Path $m.rollbackDirectory 'start-hidden.vbs'
    $rollbackShortcut=Join-Path $m.rollbackDirectory 'startup.lnk'
    if ($Restore) {
        $receipt=Get-Content -LiteralPath $m.receiptPath -Raw | ConvertFrom-Json
        Assert-Hash $m.installedLauncher $m.launcherSha256
        Assert-Hash $m.startupShortcut $receipt.installedShortcutSha256
        Assert-Hash $rollbackLauncher $m.expectedLauncherSha256
        Assert-Hash $rollbackShortcut $m.expectedShortcutSha256
        Copy-Item -LiteralPath $rollbackLauncher -Destination $m.installedLauncher -Force
        Copy-Item -LiteralPath $rollbackShortcut -Destination $m.startupShortcut -Force
        Assert-Baseline
        [pscustomobject]@{status='restored';runtimeRestarted=$false}; return
    }
    Assert-Baseline
    Assert-Hash $m.launcherSource $m.launcherSha256
    if (Test-Path -LiteralPath $m.rollbackDirectory) { throw 'startup_rollback_already_exists' }
    [void][IO.Directory]::CreateDirectory($m.rollbackDirectory)
    Copy-Item -LiteralPath $m.installedLauncher -Destination $rollbackLauncher
    Copy-Item -LiteralPath $m.startupShortcut -Destination $rollbackShortcut
    Assert-Hash $rollbackLauncher $m.expectedLauncherSha256
    Assert-Hash $rollbackShortcut $m.expectedShortcutSha256
    try {
        Copy-Item -LiteralPath $m.launcherSource -Destination $m.installedLauncher -Force
        $shortcut=(New-Object -ComObject WScript.Shell).CreateShortcut($m.startupShortcut)
        $shortcut.Arguments=$newArguments
        $shortcut.Save()
        Assert-Hash $m.installedLauncher $m.launcherSha256
        Assert-Shortcut $newArguments
        [pscustomobject]@{schema='claudegpt.fork_startup_receipt.v1';status='installed';runtimeRestarted=$false;
            installedLauncherSha256=(Hash $m.installedLauncher);installedShortcutSha256=(Hash $m.startupShortcut);
            rollbackDirectory=$m.rollbackDirectory;observedAt=[DateTime]::UtcNow.ToString('o')} |
            ConvertTo-Json | Set-Content -LiteralPath $m.receiptPath
    } catch {
        Copy-Item -LiteralPath $rollbackLauncher -Destination $m.installedLauncher -Force
        Copy-Item -LiteralPath $rollbackShortcut -Destination $m.startupShortcut -Force
        Assert-Baseline
        throw
    }
    Get-Content -LiteralPath $m.receiptPath -Raw | ConvertFrom-Json
} finally {
    if ($owns) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
