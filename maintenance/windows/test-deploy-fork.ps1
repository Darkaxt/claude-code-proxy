#requires -Version 7.2
param([Parameter(Mandatory)][string]$FixtureRoot,
      [Parameter(Mandatory)][string]$OldBinary,
      [Parameter(Mandatory)][string]$CandidateBinary,
      [Parameter(Mandatory)][string]$VerificationPath,
      [Parameter(Mandatory)][string]$SupervisorScript,
      [Parameter(Mandatory)][string]$RecoverySkillPath)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deploy-fork.ps1')
function Assert-Test($Condition, $Message) { if (-not $Condition) { throw $Message } }
if (Test-Path -LiteralPath $FixtureRoot) { throw 'Fixture root must be new.' }
[void](New-Item -ItemType Directory -Path $FixtureRoot)
$install = Join-Path $FixtureRoot 'install'
$config = Join-Path $FixtureRoot 'config'
$logs = Join-Path $FixtureRoot 'logs'
foreach ($path in @($install,$config,$logs)) { [void](New-Item -ItemType Directory -Path $path) }
Copy-Item -LiteralPath $SupervisorScript -Destination (Join-Path $install 'supervise-proxy.ps1')
$exe = Join-Path $install 'claude-code-proxy.exe'
Copy-Item -LiteralPath $OldBinary -Destination $exe
'{}' | Set-Content -LiteralPath (Join-Path $config 'config.json')
$oldVersion = (& $exe --version).Trim().Split(' ',2)[1]
$oldHash = (Get-FileHash -LiteralPath $exe).Hash
@{version=$oldVersion;sha256=$oldHash;sourceCommit=('a'*40)} | ConvertTo-Json | Set-Content (Join-Path $install 'build-info.json')
$socket = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$socket.Start(); $port=$socket.LocalEndpoint.Port; $socket.Stop()
$review = Join-Path $FixtureRoot 'consumer-review.json'
@{unresolvedConsumers=@();scope='isolated fictional fixture; no inference';reviewed=$true} | ConvertTo-Json | Set-Content $review
$version=(& $CandidateBinary --version).Trim().Split(' ',2)[1]
$instance='ClaudeGPTFixture-'+[Guid]::NewGuid().ToString('N')
$manifest=[ordered]@{
    schema='claudegpt.fork_deployment.v1'; installDirectory=$install; configDirectory=$config; logDirectory=$logs
    persistentScratch=(Join-Path $FixtureRoot 'persistent'); instanceName=$instance; existingProcessName=$instance; baseUri="http://127.0.0.1:$port"
    rollbackDirectory=(Join-Path $FixtureRoot 'rollback'); receiptPath=(Join-Path $FixtureRoot 'receipt.json')
    candidateBinary=$CandidateBinary; candidateSha256=(Get-FileHash $CandidateBinary).Hash; version=$version
    sourceCommit='191752f7d5f89a8951af43b2d289298d1540e4a2'; integratedUpstreamCommit='5261067510fd00dd5efcadab3ecf79b8e02b4f80'
    sourceRepositoryPath=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    verificationPath=$VerificationPath; verificationSha256=(Get-FileHash $VerificationPath).Hash
    expectedInstalledHash=$oldHash; expectedInstalledBuildInfoHash=(Get-FileHash (Join-Path $install 'build-info.json')).Hash
    recoverySkillPath=$RecoverySkillPath; requiredModelIds=@('gpt-6.1-sol-fast')
    protectedFiles=@(@{path=(Join-Path $config 'config.json');sha256=(Get-FileHash (Join-Path $config 'config.json')).Hash})
    consumerReviewPath=$review; consumerReviewSha256=(Get-FileHash $review).Hash
}
$manifestPath=Join-Path $FixtureRoot 'manifest.json'
$owned=$null
try {
    $owned=Start-ForkSupervisor $manifest
    $identity=Wait-ForkReady $manifest $owned @() $oldHash $oldVersion
    $manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath
    $plan=Invoke-ForkDeployment $manifestPath
    Assert-Test ($plan.status -eq 'validated') 'Default validation must not activate.'
    Assert-Test ((Get-FileHash $exe).Hash -eq $oldHash) 'Validation changed the binary.'
    $manifest.sourceCommit='3f725cd5ab31ff29d9223e7eea7eb2dfee7103c9'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath
    try { Invoke-ForkDeployment $manifestPath -Apply; throw 'Expected rejection.' } catch {
        Assert-Test ($_.Exception.Message -match 'runtime_source_tree_mismatch') 'Source binding test failed for an unrelated reason.'
    }
    $manifest.sourceCommit='191752f7d5f89a8951af43b2d289298d1540e4a2'
    $manifest.candidateSha256='0'*64
    $manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath
    try { Invoke-ForkDeployment $manifestPath -Apply; throw 'Expected rejection.' } catch {
        Assert-Test ($_.Exception.Message -match 'candidate_hash') 'Wrong-hash test failed for an unrelated reason.'
    }
    Assert-Test ((Get-ForkIdentity $manifest).child.Id -eq $identity.child.Id) 'Rejected candidate stopped the service.'
    $manifest.candidateSha256=(Get-FileHash $CandidateBinary).Hash
    @{unresolvedConsumers=@('fictional active continuation');reviewed=$true} | ConvertTo-Json | Set-Content $review
    $manifest.consumerReviewSha256=(Get-FileHash $review).Hash
    $manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath
    try { Invoke-ForkDeployment $manifestPath -Apply; throw 'Expected rejection.' } catch {
        Assert-Test ($_.Exception.Message -match 'consumer_review') 'Consumer refusal failed for an unrelated reason.'
    }
    Assert-Test ((Get-ForkIdentity $manifest).child.Id -eq $identity.child.Id) 'Consumer refusal stopped service.'
    @{unresolvedConsumers=@();reviewed=$true;scope='isolated fixture'} | ConvertTo-Json | Set-Content $review
    $manifest.consumerReviewSha256=(Get-FileHash $review).Hash
    $manifest.requiredModelIds=@('fictional-model-that-does-not-exist')
    $manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath
    try { Invoke-ForkDeployment $manifestPath -Apply; throw 'Expected activation failure.' } catch {
        $receipt=Get-Content $manifest.receiptPath -Raw | ConvertFrom-Json
        Assert-Test ($receipt.status -eq 'rolled_back' -and $receipt.rollbackVerified) 'Real activation failure did not recover.'
        $receipt | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $FixtureRoot 'rollback-result.json')
    }
    Assert-Test ((Get-FileHash $exe).Hash -eq $oldHash) 'Rollback binary differs.'
    $manifest.rollbackDirectory=Join-Path $FixtureRoot 'rollback-success'
    $manifest.requiredModelIds=@('gpt-6.1-sol-fast')
    $manifest | ConvertTo-Json -Depth 8 | Set-Content $manifestPath
    $success=Invoke-ForkDeployment $manifestPath -Apply
    Assert-Test ($success.status -eq 'deployed' -and $success.verified) 'Controlled activation failed.'
    Assert-Test ((Get-FileHash $exe).Hash -eq $manifest.candidateSha256) 'Installed hash differs.'
    [pscustomobject]@{ok=$true;checks=@('validation is non-activating','runtime source tree binding','hash rejection preserves running child','consumer refusal preserves running child','post-start failure restores and verifies rollback','successful owned activation and provenance');realInferenceRequests=0;fixture=$FixtureRoot} | ConvertTo-Json -Depth 4
} finally {
    $current=Get-ForkIdentity $manifest -AllowAbsent
    if ($current) { Stop-ForkSupervisor $manifest $current.supervisor $current.child }
    elseif ($owned -and -not $owned.HasExited) { Stop-ForkSupervisor $manifest $owned $null }
}
