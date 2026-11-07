#requires -Version 7.2
[CmdletBinding()]
param([string]$ManifestPath, [switch]$Apply)
$ErrorActionPreference = 'Stop'

function Get-ForkHash([string]$Path) {
    $file=Get-Item -LiteralPath $Path
    if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'non_regular_file' }
    return (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Assert-ForkHash([string]$Path,[string]$Expected,[string]$Code) {
    if ($Expected -notmatch '^[a-fA-F0-9]{64}$' -or (Get-ForkHash $Path) -ne $Expected) { throw $Code }
}
function Get-ForkVersion([string]$Binary) {
    $text=(& $Binary --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $text -notmatch '^claude-code-proxy (\S+)$') { throw 'version_read_failed' }
    return $Matches[1]
}
function Assert-ForkProtected($M) {
    foreach ($file in $M.protectedFiles) { Assert-ForkHash $file.path $file.sha256 'protected_file_changed' }
}
function Get-ForkModels($M) {
    $response=Invoke-RestMethod -Uri ($M.baseUri+'/v1/models') -TimeoutSec 10
    return @($response.data | ForEach-Object { $_.id } | Sort-Object)
}
function Assert-ForkPausedClients($Review,[object[]]$Clients) {
    if (-not $Clients.Count) { return }
    if ($Review.userConfirmedPause -ne $true -or
        $Review.pauseScope -ne 'listed-clients-and-continuations' -or
        [string]::IsNullOrWhiteSpace($Review.pauseAuthorizationSource)) { throw 'claude_clients_active' }
    $paused=@($Review.pausedClients)
    if ($paused.Count -ne $Clients.Count) { throw 'paused_client_set_changed' }
    foreach ($client in $Clients) {
        $match=@($paused | Where-Object { $_.pid -eq $client.Id })
        if ($match.Count -ne 1 -or $match[0].paused -ne $true -or
            $match[0].executablePath -ne $client.Path -or
            [DateTimeOffset]$match[0].started -ne [DateTimeOffset]$client.StartTime.ToUniversalTime()) {
            throw 'paused_client_identity_changed'
        }
    }
}
function Assert-ForkConsumers($M) {
    Assert-ForkHash $M.consumerReviewPath $M.consumerReviewSha256 'consumer_review_changed'
    $review=Get-Content -LiteralPath $M.consumerReviewPath -Raw | ConvertFrom-Json
    if (-not $review.reviewed -or @($review.unresolvedConsumers).Count) { throw 'consumer_review_unresolved' }
    $clients=@(Get-Process -Name claude -ErrorAction SilentlyContinue)
    Assert-ForkPausedClients $review $clients
    if ($clients.Count) {
        # A confirmed paused client may retain an idle loopback keepalive. Bind
        # both socket ends so a different producer cannot inherit that review.
        $port=([Uri]$M.baseUri).Port
        foreach ($connection in @(Get-NetTCPConnection -LocalPort $port -State Established -ErrorAction SilentlyContinue)) {
            $peers=@(Get-NetTCPConnection -LocalPort $connection.RemotePort -RemotePort $port -State Established -ErrorAction SilentlyContinue |
                Where-Object { $_.LocalAddress -eq $connection.RemoteAddress -and $_.RemoteAddress -eq $connection.LocalAddress })
            if ($peers.Count -ne 1 -or $peers[0].OwningProcess -notin @($clients.Id)) { throw 'unreviewed_proxy_connection' }
        }
    }
    $monitor=Invoke-RestMethod -Uri ($M.baseUri+'/monitor') -TimeoutSec 10
    if ($null -eq $monitor.snapshot) { throw 'monitor_unavailable' }
    if ($null -ne $monitor.snapshot.active -and @($monitor.snapshot.active).Count) { throw 'requests_active' }
}
function Read-ForkManifest([string]$Path) {
    $m=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if ($m.schema -ne 'claudegpt.fork_deployment.v1') { throw 'manifest_schema' }
    foreach ($key in @('installDirectory','configDirectory','logDirectory','persistentScratch','rollbackDirectory',
            'receiptPath','candidateBinary','verificationPath','recoverySkillPath','consumerReviewPath','sourceRepositoryPath')) {
        if (-not $m[$key] -or -not [IO.Path]::IsPathFullyQualified($m[$key])) { throw "absolute_path_required:$key" }
    }
    if ($m.persistentScratch -notmatch '^[DE]:[\\/]') { throw 'persistent_scratch_must_be_on_D_or_E' }
    $uri=[Uri]$m.baseUri
    if ($uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1') { throw 'loopback_endpoint_required' }
    if ($m.instanceName -notmatch '^[A-Za-z0-9_-]+$') { throw 'instance_name' }
    foreach ($key in @('sourceCommit','integratedUpstreamCommit')) {
        if ($m[$key] -notmatch '^[a-fA-F0-9]{40}$') { throw "commit_required:$key" }
    }
    if (-not @($m.protectedFiles).Count) { throw 'protected_files_required' }
    Assert-ForkHash $m.candidateBinary $m.candidateSha256 'candidate_hash'
    if ((Get-ForkVersion $m.candidateBinary) -ne $m.version) { throw 'candidate_version' }
    Assert-ForkHash $m.verificationPath $m.verificationSha256 'verification_hash'
    $proof=Get-Content -LiteralPath $m.verificationPath -Raw | ConvertFrom-Json
    if (-not $proof.tests_passed -or -not $proof.release_build_passed -or -not $proof.startup.ok -or
        -not $proof.startup.owned_exit_verified -or $proof.binary_sha256 -ne $m.candidateSha256 -or
        $proof.integrated_upstream_commit -ne $m.integratedUpstreamCommit) { throw 'verification_incomplete' }
    $sourceTree=(& git -C $m.sourceRepositoryPath rev-parse ($m.sourceCommit+'^{tree}')).Trim()
    if ($LASTEXITCODE -ne 0 -or $sourceTree -ne $proof.source_tree) { throw 'runtime_source_tree_mismatch' }
    if (-not (Test-Path -LiteralPath $m.recoverySkillPath -PathType Leaf)) { throw 'recovery_skill_missing' }
    Assert-ForkHash (Join-Path $m.installDirectory 'claude-code-proxy.exe') $m.expectedInstalledHash 'installed_hash_changed'
    Assert-ForkHash (Join-Path $m.installDirectory 'build-info.json') $m.expectedInstalledBuildInfoHash 'installed_provenance_changed'
    Assert-ForkProtected $m
    return $m
}
function Get-ForkIdentity($M,[switch]$AllowAbsent) {
    $uri=[Uri]$M.baseUri
    $listeners=@(Get-NetTCPConnection -State Listen -LocalPort $uri.Port -ErrorAction SilentlyContinue |
                 Where-Object { $_.LocalAddress -eq '127.0.0.1' } | Select-Object -ExpandProperty OwningProcess -Unique)
    if ($listeners.Count -eq 0 -and $AllowAbsent) { return $null }
    if ($listeners.Count -ne 1) { throw 'listener_ownership_ambiguous' }
    $child=Get-Process -Id $listeners[0]
    $exe=[IO.Path]::GetFullPath((Join-Path $M.installDirectory 'claude-code-proxy.exe'))
    if ($child.Path -ne $exe) { throw 'listener_executable_mismatch' }
    $row=Get-CimInstance Win32_Process -Filter "ProcessId=$($child.Id)"
    $parent=Get-Process -Id $row.ParentProcessId
    $parentRow=Get-CimInstance Win32_Process -Filter "ProcessId=$($parent.Id)"
    $script=Join-Path $M.installDirectory 'supervise-proxy.ps1'
    if ($parent.Path -ne (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -or
        $parentRow.CommandLine.IndexOf($script,[StringComparison]::OrdinalIgnoreCase) -lt 0) { throw 'supervisor_ownership_mismatch' }
    [pscustomobject]@{child=$child;supervisor=$parent;childStarted=$child.StartTime.ToUniversalTime().ToString('o');supervisorStarted=$parent.StartTime.ToUniversalTime().ToString('o')}
}
function Initialize-ForkWake {
    if ('ForkDeploymentWake' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
public sealed class ForkDeploymentWake : IDisposable {
    readonly AutoResetEvent signal = new AutoResetEvent(false);
    readonly FileSystemWatcher watcher;
    Process process;
    public ForkDeploymentWake(string directory) {
        watcher = new FileSystemWatcher(directory, "*.log");
        watcher.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size;
        watcher.Changed += Changed; watcher.Created += Changed;
        watcher.Renamed += Renamed; watcher.Error += Error;
        watcher.EnableRaisingEvents = true;
    }
    void Changed(object sender, FileSystemEventArgs args) { signal.Set(); }
    void Renamed(object sender, RenamedEventArgs args) { signal.Set(); }
    void Error(object sender, ErrorEventArgs args) { signal.Set(); }
    void Exited(object sender, EventArgs args) { signal.Set(); }
    public void Watch(Process child) { process=child; process.EnableRaisingEvents=true; process.Exited+=Exited; if(process.HasExited) signal.Set(); }
    public void Wait() { signal.WaitOne(); }
    public void Dispose() { watcher.Dispose(); if(process!=null) process.Exited-=Exited; signal.Dispose(); }
}
'@
}
function Start-ForkSupervisor($M) {
    Initialize-ForkWake
    $installed=Join-Path $M.installDirectory 'claude-code-proxy.exe'
    if (@(Get-CimInstance Win32_Process -Filter "Name='claude-code-proxy.exe'" |
          Where-Object { $_.ExecutablePath -eq $installed }).Count) { throw 'installed_process_already_running' }
    foreach ($path in @($M.logDirectory,$M.persistentScratch)) { [void][IO.Directory]::CreateDirectory($path) }
    $wake=[ForkDeploymentWake]::new($M.logDirectory)
    $info=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.WindowStyle='Hidden'
    $info.WorkingDirectory=$M.installDirectory
    $uri=[Uri]$M.baseUri
    foreach ($argument in @('-NoProfile','-NonInteractive','-File',(Join-Path $M.installDirectory 'supervise-proxy.ps1'),
            '-Executable',(Join-Path $M.installDirectory 'claude-code-proxy.exe'),'-ConfigDirectory',$M.configDirectory,
            '-LogDirectory',$M.logDirectory,'-InstanceName',$M.instanceName,'-ChildArguments',"serve --port $($uri.Port) --no-monitor")) {
        $info.ArgumentList.Add($argument)
    }
    # Isolated fixtures may use the supervisor's existing scoped-name option;
    # production retains its original global process-name collision guard.
    if ($M.existingProcessName) {
        $info.ArgumentList.Add('-ExistingProcessName'); $info.ArgumentList.Add($M.existingProcessName)
    }
    $info.Environment['TEMP']=$M.persistentScratch; $info.Environment['TMP']=$M.persistentScratch
    $info.Environment['CCP_APPROACH_RECOVERY_SKILL_PATH']=$M.recoverySkillPath
    # The server emits its listener-ready event only after binding. The existing
    # supervisor records content-free stderr categories, waking the observer.
    $info.Environment['CCP_LOG_STDERR']='1'
    try {
        $process=[Diagnostics.Process]::Start($info)
        $wake.Watch($process)
        $process | Add-Member -NotePropertyName ForkWake -NotePropertyValue $wake
        return $process
    } catch { $wake.Dispose(); throw }
}
function Stop-ForkSupervisor($M,$Supervisor,$Child) {
    $start=$Supervisor.StartTime
    $Supervisor.Refresh()
    if ($Supervisor.HasExited) { $Supervisor.WaitForExit(); return }
    if ($Supervisor.StartTime -ne $start) { throw 'supervisor_identity_changed' }
    $stop=[Threading.EventWaitHandle]::OpenExisting("Local\$($M.instanceName)-stop")
    try { [void]$stop.Set() } finally { $stop.Dispose() }
    if ($Child) { $Child.WaitForExit() }
    $Supervisor.WaitForExit()
    if ($Child -and -not $Child.HasExited) { throw 'owned_child_exit_unverified' }
}
function Wait-ForkReady($M,$Supervisor,$RequiredModels,[string]$Hash,[string]$Version) {
    try {
        while ($true) {
            if ($Supervisor.HasExited) { $Supervisor.WaitForExit(); throw 'supervisor_exited_during_activation' }
            $identity=Get-ForkIdentity $M -AllowAbsent
            if ($identity) {
                if ($identity.supervisor.Id -ne $Supervisor.Id) { throw 'new_supervisor_identity_mismatch' }
                try { $health=Invoke-RestMethod -Uri ($M.baseUri+'/healthz') -TimeoutSec 10 }
                catch { $Supervisor.ForkWake.Wait(); continue }
                if (-not $health.ok) { throw 'health_verification_failed' }
                $models=Get-ForkModels $M
                foreach ($required in $RequiredModels) { if ($models -notcontains $required) { throw 'model_verification_failed' } }
                $exe=Join-Path $M.installDirectory 'claude-code-proxy.exe'
                Assert-ForkHash $exe $Hash 'activation_hash_mismatch'
                if ((Get-ForkVersion $exe) -ne $Version) { throw 'activation_version_mismatch' }
                Assert-ForkProtected $M
                return $identity
            }
            $Supervisor.ForkWake.Wait()
        }
    } finally { $Supervisor.ForkWake.Dispose() }
}
function Invoke-ForkDeployment([string]$Path,[switch]$Apply) {
    $m=Read-ForkManifest $Path
    $identity=Get-ForkIdentity $m
    Assert-ForkConsumers $m
    $oldModels=Get-ForkModels $m
    $exe=Join-Path $m.installDirectory 'claude-code-proxy.exe'
    $buildInfo=Join-Path $m.installDirectory 'build-info.json'
    $oldVersion=Get-ForkVersion $exe
    if (-not $Apply) { return [pscustomobject]@{status='validated';candidateSha256=$m.candidateSha256;installedVersion=$oldVersion;childPid=$identity.child.Id;supervisorPid=$identity.supervisor.Id;activated=$false} }
    $mutex=[Threading.Mutex]::new($false,'Local\ClaudeCodeProxyUpdater-mutex')
    $owns=$false; $stopped=$false; $replacement=$null
    $receipt=[ordered]@{schema='claudegpt.fork_deployment_receipt.v1';status='preparing';verified=$false;rollbackVerified=$false;sourceCommit=$m.sourceCommit;integratedUpstreamCommit=$m.integratedUpstreamCommit;version=$m.version;sha256=$m.candidateSha256;realInferenceRequests=0;consumerReview=$m.consumerReviewPath;admissionReservationClaimed=$false}
    try {
        try { $owns=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owns=$true }
        if (-not $owns) { throw 'updater_mutex_busy' }
        $m=Read-ForkManifest $Path
        Assert-ForkConsumers $m
        $current=Get-ForkIdentity $m
        if ($current.child.Id -ne $identity.child.Id -or $current.childStarted -ne $identity.childStarted -or
            $current.supervisor.Id -ne $identity.supervisor.Id -or $current.supervisorStarted -ne $identity.supervisorStarted) { throw 'process_identity_changed' }
        if (Test-Path -LiteralPath $m.rollbackDirectory) { throw 'rollback_directory_already_exists' }
        [void][IO.Directory]::CreateDirectory($m.rollbackDirectory)
        $rollbackExe=Join-Path $m.rollbackDirectory 'claude-code-proxy.exe'
        $rollbackInfo=Join-Path $m.rollbackDirectory 'build-info.json'
        Copy-Item -LiteralPath $exe -Destination $rollbackExe
        Copy-Item -LiteralPath $buildInfo -Destination $rollbackInfo
        Assert-ForkHash $rollbackExe $m.expectedInstalledHash 'rollback_hash_mismatch'
        Assert-ForkHash $rollbackInfo $m.expectedInstalledBuildInfoHash 'rollback_provenance_mismatch'
        $receipt.rollbackBinary=$rollbackExe; $receipt.rollbackBuildInfo=$rollbackInfo
        'Restore these two verified files while the owned supervisor is stopped, restart through deploy-fork.ps1 controlled startup, then verify listener/health/version/catalog/protected hashes. The receipt binds this rollback to this activation.' | Set-Content (Join-Path $m.rollbackDirectory 'RESTORE.txt')
        Assert-ForkConsumers $m
        Stop-ForkSupervisor $m $identity.supervisor $identity.child
        $stopped=$true
        Assert-ForkProtected $m
        Assert-ForkHash $m.candidateBinary $m.candidateSha256 'candidate_changed_before_copy'
        Copy-Item -LiteralPath $m.candidateBinary -Destination $exe -Force
        $provenance=[ordered]@{version=$m.version;sha256=$m.candidateSha256;sourceCommit=$m.sourceCommit;integratedUpstreamCommit=$m.integratedUpstreamCommit;sourceRepository='https://github.com/Darkaxt/claude-code-proxy';sourceStatus='verified-fork-commit';buildKind='fork';verificationEvidence=$m.verificationPath;deploymentEnvironment=@{CCP_APPROACH_RECOVERY_SKILL_PATH=$m.recoverySkillPath};status='activation_in_progress'}
        $provenance | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $buildInfo
        $replacement=Start-ForkSupervisor $m
        $new=Wait-ForkReady $m $replacement $m.requiredModelIds $m.candidateSha256 $m.version
        $provenance.status='deployed_health_verified'; $provenance.deployed=$true
        $provenance.deploymentVerifiedAt=[DateTime]::UtcNow.ToString('o')
        $provenance | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $buildInfo
        $receipt.status='deployed'; $receipt.verified=$true
        $receipt.childPid=$new.child.Id; $receipt.childStarted=$new.childStarted
        $receipt.supervisorPid=$new.supervisor.Id; $receipt.supervisorStarted=$new.supervisorStarted
        $receipt.listenerExecutable=$new.child.Path; $receipt.modelCount=@(Get-ForkModels $m).Count
        $receipt.persistentScratch=$m.persistentScratch
    } catch {
        $receipt.failureType=$_.Exception.GetType().FullName
        $receipt.failureCode=$_.Exception.Message
        if ($stopped) {
            try {
                if ($replacement -and -not $replacement.HasExited) {
                    $childRow=Get-CimInstance Win32_Process -Filter "ParentProcessId=$($replacement.Id)" | Where-Object { $_.ExecutablePath -eq $exe }
                    $child=$null; if ($childRow) { $child=Get-Process -Id $childRow.ProcessId }
                    Stop-ForkSupervisor $m $replacement $child
                }
                Copy-Item -LiteralPath $rollbackExe -Destination $exe -Force
                Copy-Item -LiteralPath $rollbackInfo -Destination $buildInfo -Force
                $recovery=Start-ForkSupervisor $m
                $restored=Wait-ForkReady $m $recovery $oldModels $m.expectedInstalledHash $oldVersion
                Assert-ForkHash $buildInfo $m.expectedInstalledBuildInfoHash 'rollback_provenance_restore_mismatch'
                $receipt.status='rolled_back'; $receipt.rollbackVerified=$true; $receipt.restoredPid=$restored.child.Id
            } catch { $receipt.status='recovery_incomplete'; $receipt.recoveryFailureType=$_.Exception.GetType().FullName }
        } else { $receipt.status='refused_before_stop' }
        throw
    } finally {
        $receipt.observedAt=[DateTime]::UtcNow.ToString('o')
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $m.receiptPath))
        $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $m.receiptPath
        if ($owns) { $mutex.ReleaseMutex() }; $mutex.Dispose()
    }
    return [pscustomobject]$receipt
}
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $ManifestPath) { throw 'ManifestPath is required.' }
    Invoke-ForkDeployment $ManifestPath -Apply:$Apply
}
