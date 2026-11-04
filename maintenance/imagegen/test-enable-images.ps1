#Requires -Version 7.4
param([Parameter(Mandatory)][string]$FixtureRoot,[Parameter(Mandatory)][string]$RuntimeManifest,[Parameter(Mandatory)][string]$ResultPath)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$true
$env:TEMP=$FixtureRoot;$env:TMP=$FixtureRoot
. (Join-Path $PSScriptRoot '../windows/deploy-fork.ps1')
if(Test-Path -LiteralPath $FixtureRoot){throw 'Fixture root must be new'}
$production=Get-Content -LiteralPath $RuntimeManifest -Raw|ConvertFrom-Json -AsHashtable
foreach($folder in @('install','config','logs')){[void][IO.Directory]::CreateDirectory((Join-Path $FixtureRoot $folder))}
$install=Join-Path $FixtureRoot 'install';$config=Join-Path $FixtureRoot 'config'
Copy-Item (Join-Path $production.installDirectory 'supervise-proxy.ps1') (Join-Path $install 'supervise-proxy.ps1')
Copy-Item $production.candidateBinary (Join-Path $install 'claude-code-proxy.exe')
Copy-Item (Join-Path $production.installDirectory 'build-info.json') (Join-Path $install 'build-info.json')
$socket=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$socket.Start();$port=$socket.LocalEndpoint.Port;$socket.Stop()
$cfg=Join-Path $config 'config.json'
@{port=$port;codex=@{imagesApi=$false}}|ConvertTo-Json -Depth 5|Set-Content $cfg -Encoding utf8NoBOM
$next=Join-Path $FixtureRoot 'updated-config.json'
@{port=$port;codex=@{imagesApi=$true}}|ConvertTo-Json -Depth 5|Set-Content $next -Encoding utf8NoBOM
$review=Join-Path $FixtureRoot 'consumers.json'
@{reviewed=$true;unresolvedConsumers=@();scope='isolated image-gate fixture, no inference'}|ConvertTo-Json|Set-Content $review
$m=$production.Clone()
$m.installDirectory=$install;$m.configDirectory=$config;$m.logDirectory=Join-Path $FixtureRoot 'logs';$m.persistentScratch=Join-Path $FixtureRoot 'persistent'
$m.instanceName='ClaudeGPTImageFixture-'+[Guid]::NewGuid().ToString('N');$m.existingProcessName=$m.instanceName;$m.baseUri="http://127.0.0.1:$port"
$m.expectedInstalledHash=Get-ForkHash (Join-Path $install 'claude-code-proxy.exe');$m.expectedInstalledBuildInfoHash=Get-ForkHash (Join-Path $install 'build-info.json')
$m.protectedFiles=@(@{path=$cfg;sha256=(Get-ForkHash $cfg)})
$m.consumerReviewPath=$review;$m.consumerReviewSha256=Get-ForkHash $review;$m.requiredModelIds=@('gpt-6.1-sol')
$m.rollbackDirectory=Join-Path $FixtureRoot 'unused-standard-rollback';$m.receiptPath=Join-Path $FixtureRoot 'unused-standard-receipt.json'
$m.imagegenOriginalHash=Get-ForkHash $cfg;$m.imagegenUpdatedConfig=$next;$m.imagegenEnabledHash=Get-ForkHash $next
$m.imagegenRollbackDirectory=Join-Path $FixtureRoot 'gate-rollback';$m.imagegenReceiptPath=Join-Path $FixtureRoot 'gate-receipt.json'
$manifest=Join-Path $FixtureRoot 'manifest.json'
$m|ConvertTo-Json -Depth 15|Set-Content $manifest -Encoding utf8NoBOM
$enable=Join-Path $PSScriptRoot 'enable-images.ps1'
$owned=$null
try{
 $owned=Start-ForkSupervisor $m
 $initial=Wait-ForkReady $m $owned @() $m.candidateSha256 $m.version
 & $enable -Manifest $manifest
 if((Get-ForkIdentity $m).child.Id -ne $initial.child.Id){throw 'Validation restarted fixture'}
 & $enable -Manifest $manifest -Mode Enable
 $receipt=Get-Content $m.imagegenReceiptPath -Raw|ConvertFrom-Json
 if($receipt.status -ne 'enabled_verified' -or (Get-ForkHash $cfg) -ne $m.imagegenEnabledHash){throw 'Enable did not verify'}
 & $enable -Manifest $manifest -Mode Restore
 if((Get-ForkHash $cfg) -ne $m.imagegenOriginalHash){throw 'Explicit restore failed'}
 $m.requiredModelIds=@('fictional-model-that-does-not-exist');$m.imagegenRollbackDirectory=Join-Path $FixtureRoot 'failed-rollback';$m.imagegenReceiptPath=Join-Path $FixtureRoot 'failed-receipt.json'
 $m|ConvertTo-Json -Depth 15|Set-Content $manifest -Encoding utf8NoBOM
 $caught=$false
 try{& $enable -Manifest $manifest -Mode Enable}catch{$caught=$true}
 $recovery=Get-Content $m.imagegenReceiptPath -Raw|ConvertFrom-Json
 if(-not $caught -or $recovery.status -ne 'rolled_back_verified' -or $recovery.failure -ne 'model_verification_failed' -or (Get-ForkHash $cfg) -ne $m.imagegenOriginalHash){throw 'Fictional post-start failure did not restore verified original state'}
 @{passed=$true;checks=@('validation leaves process/config intact','owned image-gate activation and HTTP 405','explicit config restore and HTTP 404','fictional post-start failure restores config/service');realInferenceRequests=0;liveInstallationChanged=$false;binaryAndBuildInfoUnchanged=$true}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $ResultPath -Encoding utf8NoBOM
 Write-Output 'Isolated image-gate activation and recovery fixtures passed.'
}finally{
 $current=Get-ForkIdentity $m -AllowAbsent
 if($current){Stop-ForkSupervisor $m $current.supervisor $current.child}
 elseif($owned -and -not $owned.HasExited){Stop-ForkSupervisor $m $owned $null}
}
