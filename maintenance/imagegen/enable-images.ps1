#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Manifest,[ValidateSet('Validate','Enable','Restore')][string]$Mode='Validate',[string]$LifecycleScript)
$ErrorActionPreference='Stop'
if(-not $LifecycleScript){
 $LifecycleScript=Join-Path $PSScriptRoot '../windows/deploy-fork.ps1'
 if(-not(Test-Path -LiteralPath $LifecycleScript)){$LifecycleScript=Join-Path $PSScriptRoot 'deploy-fork.ps1'}
}
. $LifecycleScript
$m=Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json -AsHashtable
$manifestHash=Get-ForkHash $Manifest
$config=Join-Path $m.configDirectory 'config.json'
$receiptPath=$m.imagegenReceiptPath
$rollback=$m.imagegenRollbackDirectory
$oldConfig=Join-Path $rollback 'config.json'
$buildInfo=Join-Path $m.installDirectory 'build-info.json'
$exe=Join-Path $m.installDirectory 'claude-code-proxy.exe'
function Set-ConfigProof([string]$Expected){
 $matched=0
 foreach($file in $m.protectedFiles){if($file.path -eq $config){$file.sha256=$Expected;$matched++}}
 if($matched -ne 1){throw 'exact_config_protection_required'}
}
function Replace-Config([string]$Source,[string]$Expected){
 Assert-ForkHash $config $Expected 'config_changed'
 $pending="$config.imagegen-new"
 if(Test-Path -LiteralPath $pending){throw 'unfinished_imagegen_config_staging'}
 Copy-Item -LiteralPath $Source -Destination $pending
 Assert-ForkHash $pending (Get-ForkHash $Source) 'config_staging_changed'
 Assert-ForkHash $config $Expected 'config_changed_before_replace'
 [IO.File]::Replace($pending,$config,[NullString]::Value)
 Assert-ForkHash $config (Get-ForkHash $Source) 'config_replace_failed'
}
function Save-Result($Value){$Value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM}
if($Mode -eq 'Restore'){
 $prior=Get-Content -LiteralPath $receiptPath -Raw|ConvertFrom-Json
 if($prior.manifestSha256 -ne $manifestHash -or $prior.status -ne 'enabled_verified'){throw 'restore_receipt_mismatch'}
 Assert-ForkHash $oldConfig $m.imagegenOriginalHash 'rollback_config_changed'
 Set-ConfigProof $m.imagegenEnabledHash
}else{
 $m=Read-ForkManifest $Manifest
 Assert-ForkHash $config $m.imagegenOriginalHash 'original_config_changed'
 Assert-ForkHash $m.imagegenUpdatedConfig $m.imagegenEnabledHash 'updated_config_changed'
 $expected=Get-Content -LiteralPath $config -Raw|ConvertFrom-Json -AsHashtable
 if(-not $expected.ContainsKey('codex')){$expected.codex=@{}}
 $expected.codex.imagesApi=$true
 $proposed=Get-Content -LiteralPath $m.imagegenUpdatedConfig -Raw|ConvertFrom-Json -AsHashtable
 if(-not [System.Text.Json.Nodes.JsonNode]::DeepEquals([System.Text.Json.Nodes.JsonNode]::Parse(($expected|ConvertTo-Json -Depth 100 -Compress)),[System.Text.Json.Nodes.JsonNode]::Parse(($proposed|ConvertTo-Json -Depth 100 -Compress)))){throw 'config_change_exceeds_images_gate'}
}
Assert-ForkHash $exe $m.candidateSha256 'installed_binary_changed'
Assert-ForkHash $buildInfo $m.expectedInstalledBuildInfoHash 'installed_provenance_changed'
Assert-ForkProtected $m
Assert-ForkConsumers $m
$identity=Get-ForkIdentity $m
$models=Get-ForkModels $m
$version=Get-ForkVersion $exe
if($Mode -eq 'Validate'){Write-Output 'Image gate/config/lifecycle inputs validated; no live change.';return}
$mutex=[Threading.Mutex]::new($false,'Local\ClaudeCodeProxyUpdater-mutex')
$held=$false;$stopped=$false;$replacement=$null
try{
 try{$held=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$held=$true}
 if(-not $held){throw 'updater_mutex_busy'}
 Assert-ForkProtected $m;Assert-ForkConsumers $m
 $fresh=Get-ForkIdentity $m
 if($fresh.child.Id -ne $identity.child.Id -or $fresh.childStarted -ne $identity.childStarted -or $fresh.supervisor.Id -ne $identity.supervisor.Id -or $fresh.supervisorStarted -ne $identity.supervisorStarted){throw 'process_identity_changed'}
 if($Mode -eq 'Enable'){
  if(Test-Path -LiteralPath $rollback){throw 'imagegen_rollback_already_exists'}
  [void][IO.Directory]::CreateDirectory($rollback)
  Copy-Item -LiteralPath $config -Destination $oldConfig
  Copy-Item -LiteralPath $buildInfo -Destination (Join-Path $rollback 'build-info.json')
  Assert-ForkHash $oldConfig $m.imagegenOriginalHash 'rollback_config_mismatch'
  Save-Result @{status='rollback_saved';manifestSha256=$manifestHash;rollbackBinary=$m.candidateBinary;rollbackConfig=$oldConfig;rollbackBuildInfo=(Join-Path $rollback 'build-info.json')}
 }
 try{
  Assert-ForkConsumers $m
  Stop-ForkSupervisor $m $identity.supervisor $identity.child
  $stopped=$true
  if($Mode -eq 'Enable'){
   Replace-Config $m.imagegenUpdatedConfig $m.imagegenOriginalHash
   Set-ConfigProof $m.imagegenEnabledHash
  }else{
   Replace-Config $oldConfig $m.imagegenEnabledHash
   Set-ConfigProof $m.imagegenOriginalHash
  }
  $replacement=Start-ForkSupervisor $m
  $required=if($Mode -eq 'Enable'){$m.requiredModelIds}else{$models}
  $ready=Wait-ForkReady $m $replacement $required $m.candidateSha256 $version
  Assert-ForkHash $buildInfo $m.expectedInstalledBuildInfoHash 'provenance_changed_during_restart'
  $route=Invoke-WebRequest -Uri ($m.baseUri+'/v1/images/generations') -Method Get -SkipHttpErrorCheck -TimeoutSec 10
  $expectedStatus=if($Mode -eq 'Enable'){405}else{404}
  if([int]$route.StatusCode -ne $expectedStatus){throw 'image_route_state_mismatch'}
  Save-Result @{schema='claudegpt.imagegen_config_activation.v1';status=$(if($Mode -eq 'Enable'){'enabled_verified'}else{'restored_verified'});at=[DateTime]::UtcNow.ToString('o');manifestSha256=$manifestHash;binarySha256=$m.candidateSha256;binaryChanged=$false;buildInfoChanged=$false;configSha256=(Get-ForkHash $config);rollbackBinary=$m.candidateBinary;rollbackConfig=$oldConfig;rollbackBuildInfo=(Join-Path $rollback 'build-info.json');oldChildPid=$identity.child.Id;oldChildStarted=$identity.childStarted;oldSupervisorPid=$identity.supervisor.Id;oldProcessesExited=$true;childPid=$ready.child.Id;childStarted=$ready.childStarted;supervisorPid=$ready.supervisor.Id;supervisorStarted=$ready.supervisorStarted;healthVerified=$true;modelCount=@(Get-ForkModels $m).Count;imageRouteStatus=[int]$route.StatusCode}
  Write-Output "Image gate $Mode completed and independently verified."
 }catch{
  $failure=$_.Exception.Message
  if(-not $stopped){throw}
  try{
   Assert-ForkConsumers $m
   $current=Get-ForkIdentity $m -AllowAbsent
   if($current){if(-not $replacement -or $current.supervisor.Id -ne $replacement.Id){throw 'recovery_process_ownership_changed'};Stop-ForkSupervisor $m $current.supervisor $current.child}
   $now=Get-ForkHash $config
   if($now -eq $m.imagegenEnabledHash){Replace-Config $oldConfig $m.imagegenEnabledHash}
   elseif($now -ne $m.imagegenOriginalHash){throw 'recovery_config_changed_by_other_writer'}
   Set-ConfigProof $m.imagegenOriginalHash
   $recovery=Start-ForkSupervisor $m
   $restored=Wait-ForkReady $m $recovery $models $m.candidateSha256 $version
   Save-Result @{status='rolled_back_verified';failure=$failure;manifestSha256=$manifestHash;configSha256=(Get-ForkHash $config);childPid=$restored.child.Id;supervisorPid=$restored.supervisor.Id;healthVerified=$true}
  }catch{Save-Result @{status='recovery_incomplete';failure=$failure;recoveryFailure=$_.Exception.Message;manifestSha256=$manifestHash};throw}
  throw "Image gate activation failed; original config/service restored: $failure"
 }
}finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
