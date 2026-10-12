param(
    [ValidateSet('Check','Apply')][string]$Mode = 'Check',
    [string]$InstallDirectory = "$env:LOCALAPPDATA\Programs\claude-code-proxy",
    [string]$StateDirectory = "$env:LOCALAPPDATA\claude-code-proxy\updater",
    [string]$Repository = 'raine/claude-code-proxy',
    [string]$ApiUrl,
    [switch]$NoApply
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $ApiUrl) { $ApiUrl = "https://api.github.com/repos/$Repository/releases/latest" }

$executable = Join-Path $InstallDirectory 'claude-code-proxy.exe'
$stopScript = Join-Path $InstallDirectory 'stop-proxy.ps1'
$startLauncher = Join-Path $InstallDirectory 'start-hidden.vbs'
$pendingPath = Join-Path $StateDirectory 'pending.json'
$logPath = Join-Path $StateDirectory 'updater.log'
$mutex = $null
$ownsMutex = $false

function Write-UpdaterLog {
    param([string]$Event, [hashtable]$Fields = @{})
    New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1MB) {
        $rotated = "$logPath.1"
        if (Test-Path -LiteralPath $rotated) { Remove-Item -LiteralPath $rotated -Force }
        Move-Item -LiteralPath $logPath -Destination $rotated
    }
    $parts = @([DateTime]::UtcNow.ToString('o'), "event=$Event")
    foreach ($key in ($Fields.Keys | Sort-Object)) {
        $value = [string]$Fields[$key]
        $parts += "$key=$($value -replace '\s+', '_')"
    }
    [System.IO.File]::AppendAllText($logPath, (($parts -join ' ') + [Environment]::NewLine))
}

function Get-VersionFromTag([string]$Tag) {
    $clean = $Tag.TrimStart('v')
    $parsed = $null
    if (-not [Version]::TryParse($clean, [ref]$parsed)) { throw "Invalid release tag: $Tag" }
    return $parsed
}

function Get-InstalledPackageVersion {
    if (-not (Test-Path -LiteralPath $executable)) { throw "Proxy executable not found: $executable" }
    # Consume the native command to completion before reading LASTEXITCODE.
    # Select-Object -First 1 can stop the pipeline before that value is set.
    $lines = @(& $executable --version 2>&1)
    $line = [string]($lines | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or $line -notmatch '^claude-code-proxy\s+(\S+)\s*$') { throw "Cannot parse installed version from: $line" }
    return $Matches[1]
}

function Get-InstalledVersion {
    $packageVersion = Get-InstalledPackageVersion
    if ($packageVersion -notmatch '^(\d+\.\d+\.\d+)(?:-|$)') { throw "Cannot parse installed version: $packageVersion" }
    return [Version]$Matches[1]
}

function Get-StockUpdateBlockReason {
    param([string]$PackageVersion, $BuildInfo, [string]$InstalledHash)
    if ($PackageVersion -notmatch '^\d+\.\d+\.\d+$') { return 'custom-package-version' }
    if (-not $BuildInfo) { return 'unverified-build-provenance' }
    $officialRepository = 'https://github.com/raine/claude-code-proxy'
    # Both metadata schemas have been used locally. Never let stale official
    # fields override a newer fork sourceRepository field (or vice versa).
    if ($BuildInfo.sourceRepository -and $BuildInfo.sourceRepository -ne $officialRepository) { return 'fork-build-provenance' }
    if ($BuildInfo.repository -ne $officialRepository -or
        $BuildInfo.build_kind -ne 'official Windows amd64 release') { return 'unverified-build-provenance' }
    if ($InstalledHash -notmatch '^[0-9a-fA-F]{64}$' -or
        $BuildInfo.binary_sha256 -ne $InstalledHash) { return 'build-provenance-hash-mismatch' }
    return $null
}

function Get-InstalledUpdateBlockReason {
    $packageVersion = Get-InstalledPackageVersion
    $buildInfoPath = Join-Path $InstallDirectory 'build-info.json'
    $buildInfo = $null
    if (Test-Path -LiteralPath $buildInfoPath) {
        try { $buildInfo = Get-Content -LiteralPath $buildInfoPath -Raw | ConvertFrom-Json }
        catch { return 'invalid-build-provenance' }
    }
    return Get-StockUpdateBlockReason -PackageVersion $packageVersion -BuildInfo $buildInfo -InstalledHash (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
}

function Get-ClaudeProcesses {
    @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -match '(?i)[\\/]@anthropic-ai[\\/]claude-code[\\/]' })
}

function Save-PendingRelease($Release) {
    $asset = @($Release.assets | Where-Object { $_.name -eq 'claude-code-proxy-windows-amd64.zip' })
    if ($asset.Count -ne 1) { throw 'Official Windows amd64 release asset is missing or ambiguous.' }
    if ($asset[0].digest -notmatch '^sha256:([0-9a-fA-F]{64})$') { throw 'Release asset has no usable SHA-256 digest.' }
    $expectedHash = $Matches[1].ToUpperInvariant()
    $version = Get-VersionFromTag $Release.tag_name
    $stageDirectory = Join-Path $StateDirectory ("stage-v" + $version)
    New-Item -ItemType Directory -Path $stageDirectory -Force | Out-Null
    $archivePath = Join-Path $stageDirectory 'release.zip'
    $downloadPath = Join-Path $stageDirectory 'release.download'
    if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath -Force }
    Invoke-WebRequest -Uri $asset[0].browser_download_url -OutFile $downloadPath -Headers @{ 'User-Agent' = 'claude-code-proxy-updater' }
    $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) { Remove-Item -LiteralPath $downloadPath -Force; throw 'Downloaded release digest mismatch.' }
    Move-Item -LiteralPath $downloadPath -Destination $archivePath -Force
    $pending = [ordered]@{
        version = $version.ToString()
        tag = [string]$Release.tag_name
        release_url = [string]$Release.html_url
        archive_path = $archivePath
        archive_sha256 = $expectedHash
        staged_utc = [DateTime]::UtcNow.ToString('o')
    }
    $pendingTemp = "$pendingPath.tmp"
    [System.IO.File]::WriteAllText($pendingTemp, ($pending | ConvertTo-Json -Depth 4))
    Move-Item -LiteralPath $pendingTemp -Destination $pendingPath -Force
    Write-UpdaterLog 'release-staged' @{ version = $version; sha256 = $expectedHash }
}

function Start-ProxyAndVerify([Version]$ExpectedVersion) {
    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
    Start-Process -FilePath $wscript -ArgumentList @('//B','//Nologo',("`"$startLauncher`"")) -WindowStyle Hidden
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        try {
            $health = Invoke-RestMethod -Uri 'http://127.0.0.1:8317/healthz' -Method Get
            if ($health.ok -eq $true -and (Get-InstalledVersion) -eq $ExpectedVersion) { return }
        } catch {
            Start-Sleep -Milliseconds 250
        }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Updated proxy did not pass local health verification within 30 seconds.'
}

function Stop-OwnedProxy {
    $proxy = @(Get-CimInstance Win32_Process -Filter "Name='claude-code-proxy.exe'")
    if ($proxy.Count -eq 0) { return }
    if ($proxy.Count -ne 1 -or $proxy[0].ExecutablePath -ne $executable) { throw 'Proxy process ownership is ambiguous.' }
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($proxy[0].ParentProcessId)"
    if (-not $parent -or $parent.CommandLine -notmatch '(?i)supervise-proxy\.ps1') { throw 'Proxy is not owned by the expected supervisor.' }
    $parentProcess = Get-Process -Id $parent.ProcessId
    & $stopScript | Out-Null
    $parentProcess.WaitForExit()
    if (Get-Process -Name 'claude-code-proxy' -ErrorAction SilentlyContinue) { throw 'Proxy remained running after supervisor stop.' }
}

function Apply-PendingRelease {
    if (-not (Test-Path -LiteralPath $pendingPath)) { return }
    $blockReason = Get-InstalledUpdateBlockReason
    if ($blockReason) {
        Write-UpdaterLog 'fork-integration-required' @{ mode = 'Apply'; installed = (Get-InstalledPackageVersion); reason = $blockReason; action = 'integrate-upstream-in-patched-fork'; pending = 'preserved' }
        return
    }
    $claude = Get-ClaudeProcesses
    if ($claude.Count -gt 0) {
        Write-UpdaterLog 'apply-deferred' @{ reason = 'claude-running'; pids = (($claude.ProcessId | Sort-Object) -join ',') }
        return
    }

    $pending = Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json
    $targetVersion = [Version]$pending.version
    $installedVersion = Get-InstalledVersion
    if ($targetVersion -le $installedVersion) {
        Remove-Item -LiteralPath $pendingPath -Force
        Write-UpdaterLog 'pending-obsolete' @{ installed = $installedVersion; pending = $targetVersion }
        return
    }
    if (-not (Test-Path -LiteralPath $pending.archive_path)) { throw 'Pending release archive is missing.' }
    if ((Get-FileHash -LiteralPath $pending.archive_path -Algorithm SHA256).Hash -ne $pending.archive_sha256) { throw 'Pending archive digest changed.' }

    $extractDirectory = Join-Path (Split-Path -Parent $pending.archive_path) 'extracted'
    if (Test-Path -LiteralPath $extractDirectory) { Remove-Item -LiteralPath $extractDirectory -Recurse -Force }
    Expand-Archive -LiteralPath $pending.archive_path -DestinationPath $extractDirectory
    $candidate = Join-Path $extractDirectory 'claude-code-proxy.exe'
    $candidateLine = (& $candidate --version 2>&1 | Select-Object -First 1)
    if ($candidateLine -notmatch '(\d+\.\d+\.\d+)' -or [Version]$Matches[1] -ne $targetVersion) { throw 'Staged executable version does not match the release.' }

    # Recheck immediately before stopping the supervisor. An open Claude CLI is a hard defer condition.
    $claude = Get-ClaudeProcesses
    if ($claude.Count -gt 0) {
        Write-UpdaterLog 'apply-deferred' @{ reason = 'claude-started-during-staging'; pids = (($claude.ProcessId | Sort-Object) -join ',') }
        return
    }

    $configPath = Join-Path $env:APPDATA 'claude-code-proxy\config.json'
    $authPath = Join-Path $env:APPDATA 'claude-code-proxy\codex\auth.json'
    $configHash = if (Test-Path -LiteralPath $configPath) { (Get-FileHash -LiteralPath $configPath).Hash } else { $null }
    $authHash = if (Test-Path -LiteralPath $authPath) { (Get-FileHash -LiteralPath $authPath).Hash } else { $null }
    $backupPath = Join-Path $StateDirectory ("rollback-" + $installedVersion + '.exe')
    Copy-Item -LiteralPath $executable -Destination $backupPath -Force

    $stopped = $false
    try {
        Stop-OwnedProxy
        $stopped = $true
        Copy-Item -LiteralPath $candidate -Destination $executable -Force
        if ((Get-InstalledVersion) -ne $targetVersion) { throw 'Installed executable version verification failed.' }
        Start-ProxyAndVerify $targetVersion
        if ($configHash -and (Get-FileHash -LiteralPath $configPath).Hash -ne $configHash) { throw 'Proxy configuration changed during update.' }
        if ($authHash -and (Get-FileHash -LiteralPath $authPath).Hash -ne $authHash) { throw 'OAuth data changed during update.' }

        $buildInfoPath = Join-Path $InstallDirectory 'build-info.json'
        $buildInfo = if (Test-Path -LiteralPath $buildInfoPath) { Get-Content -LiteralPath $buildInfoPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
        $buildInfo | Add-Member -NotePropertyName repository -NotePropertyValue "https://github.com/$Repository" -Force
        $buildInfo | Add-Member -NotePropertyName package_version -NotePropertyValue $targetVersion.ToString() -Force
        $buildInfo | Add-Member -NotePropertyName build_kind -NotePropertyValue 'official Windows amd64 release' -Force
        $buildInfo | Add-Member -NotePropertyName installed_on -NotePropertyValue ([DateTime]::Now.ToString('yyyy-MM-dd')) -Force
        $buildInfo | Add-Member -NotePropertyName release_url -NotePropertyValue ([string]$pending.release_url) -Force
        $buildInfo | Add-Member -NotePropertyName archive_sha256 -NotePropertyValue ([string]$pending.archive_sha256) -Force
        $buildInfo | Add-Member -NotePropertyName binary_sha256 -NotePropertyValue ((Get-FileHash -LiteralPath $executable).Hash) -Force
        $buildInfo | Add-Member -NotePropertyName rollback -NotePropertyValue "Use the updater rollback executable for v$installedVersion if retained after a failed update; otherwise reinstall that official release while preserving config and OAuth." -Force
        [System.IO.File]::WriteAllText($buildInfoPath, (($buildInfo | ConvertTo-Json -Depth 5) + [Environment]::NewLine))

        Remove-Item -LiteralPath $pendingPath -Force
        Remove-Item -LiteralPath $backupPath -Force
        Remove-Item -LiteralPath (Split-Path -Parent $pending.archive_path) -Recurse -Force
        Write-UpdaterLog 'update-installed' @{ from = $installedVersion; to = $targetVersion }
    } catch {
        $failure = $_.Exception.Message
        if ($stopped -and (Test-Path -LiteralPath $backupPath)) {
            try {
                try { Stop-OwnedProxy } catch { }
                Copy-Item -LiteralPath $backupPath -Destination $executable -Force
                Start-ProxyAndVerify $installedVersion
                Write-UpdaterLog 'update-rolled-back' @{ version = $installedVersion; failure = $failure }
            } catch {
                Write-UpdaterLog 'rollback-failed' @{ version = $installedVersion; failure = $_.Exception.GetType().Name }
            }
        }
        throw
    }
}

try {
    $mutex = [Threading.Mutex]::new($false, 'Local\ClaudeCodeProxyUpdater-mutex')
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { exit 0 }
    New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null

    if ($Mode -eq 'Check') {
        $release = Invoke-RestMethod -Uri $ApiUrl -Headers @{ 'User-Agent' = 'claude-code-proxy-updater'; 'Accept' = 'application/vnd.github+json' }
        $latestVersion = Get-VersionFromTag $release.tag_name
        $installedVersion = Get-InstalledVersion
        Write-UpdaterLog 'update-check' @{ installed = (Get-InstalledPackageVersion); latest = $latestVersion }
        $blockReason = Get-InstalledUpdateBlockReason
        if ($blockReason) {
            Write-UpdaterLog 'fork-integration-required' @{ mode = 'Check'; installed = (Get-InstalledPackageVersion); latest = $latestVersion; reason = $blockReason; action = 'integrate-upstream-in-patched-fork' }
            exit 0
        }
        if ($latestVersion -gt $installedVersion) { Save-PendingRelease $release }
        if (-not $NoApply) { Apply-PendingRelease }
    } else {
        Apply-PendingRelease
    }
    exit 0
} catch {
    Write-UpdaterLog 'updater-failed' @{ mode = $Mode; type = $_.Exception.GetType().Name; message = $_.Exception.Message }
    exit 1
} finally {
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
}
