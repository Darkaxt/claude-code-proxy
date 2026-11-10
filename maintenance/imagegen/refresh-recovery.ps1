#Requires -Version 7.4
param([Parameter(Mandatory)][string]$RuntimeManifest,[Parameter(Mandatory)][string]$RecoveryDirectory,[Parameter(Mandatory)][string]$ImageActive,[Parameter(Mandatory)][string]$ClientActive,[Parameter(Mandatory)][string]$FixtureResult)
$ErrorActionPreference='Stop'
function Read($p){Get-Content -LiteralPath $p -Raw|ConvertFrom-Json -AsHashtable}
function Hash($p){(Get-FileHash -LiteralPath $p).Hash.ToLowerInvariant()}
function Save($v,$p){$v|ConvertTo-Json -Depth 100|Set-Content -LiteralPath $p -Encoding utf8NoBOM}
$clientMutex=[Threading.Mutex]::new($false,'Local\ClaudeGPTClientMaintenance')
$proxyMutex=[Threading.Mutex]::new($false,'Local\ClaudeCodeProxyUpdater-mutex')
$clientHeld=$false;$proxyHeld=$false
try{
try{$clientHeld=$clientMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$clientHeld=$true}
if(-not $clientHeld){throw 'Client maintenance busy'}
try{$proxyHeld=$proxyMutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$proxyHeld=$true}
if(-not $proxyHeld){throw 'Proxy maintenance busy'}
$fixtures=Read $FixtureResult
if(-not $fixtures.passed -or $fixtures.liveInstallationChanged){throw 'Required isolated recovery fixtures missing'}
if(Test-Path $RecoveryDirectory){throw 'Recovery destination exists; resolve it first'}
$imageHash=Hash $ImageActive;$clientHash=Hash $ClientActive
$image=Read $ImageActive;$client=Read $ClientActive
$priorRecoveryPackage=$image.rollback.recoveryPackage
if($client.pendingCandidate){throw 'Resolve unfinished client before rebinding recovery'}
$originalState=Split-Path $image.activationReceipt
$originalManifest=Join-Path $originalState 'activation-manifest.json'
foreach($f in $image.files){if((Hash (Join-Path $image.releaseDirectory $f.file)) -ne $f.sha256){throw 'Image release input changed'}}
if((Hash 'C:\Users\darka\.local\bin\claude.exe') -ne $client.sha256){throw 'Client provenance changed'}
$runtime=Read $RuntimeManifest
. (Join-Path $PSScriptRoot '../windows/deploy-fork.ps1')
$null=Read-ForkManifest $RuntimeManifest
Assert-ForkConsumers $runtime
[void][IO.Directory]::CreateDirectory($RecoveryDirectory)
foreach($file in @('enable-images.ps1','restore-integration.ps1','restore-client.ps1')){Copy-Item (Join-Path $PSScriptRoot $file) (Join-Path $RecoveryDirectory $file)}
Copy-Item $RuntimeManifest (Join-Path $RecoveryDirectory 'runtime-manifest.json')
Copy-Item (Join-Path $PSScriptRoot '../windows/deploy-fork.ps1') (Join-Path $RecoveryDirectory 'deploy-fork.ps1')
$package=@{schema='claudegpt.image_recovery.v1';originalState=$originalState;originalManifest=$originalManifest;originalManifestSha256=(Hash $originalManifest);clientInstallReceipt=(Join-Path $originalState 'client-install.json');clientBinary='C:\Users\darka\.local\bin\claude.exe';clientSha256=$client.sha256;runtimeManifest=(Join-Path $RecoveryDirectory 'runtime-manifest.json');helper=(Join-Path $RecoveryDirectory 'enable-images.ps1');lifecycle=(Join-Path $RecoveryDirectory 'deploy-fork.ps1');fixtureResult=$FixtureResult;sourceCommit=(& git -C (Join-Path $PSScriptRoot '../..') rev-parse HEAD).Trim()}
$package.runtimeManifestSha256=Hash $package.runtimeManifest;$package.helperSha256=Hash $package.helper;$package.lifecycleSha256=Hash $package.lifecycle
$packagePath=Join-Path $RecoveryDirectory 'package.json'
Save $package $packagePath
& (Join-Path $RecoveryDirectory 'restore-integration.ps1') -RecoveryPackage $packagePath -ValidateOnly
if(-not $image.originalRecovery){$image.originalRecovery=$image.rollback}
if(-not $image.originalRuntimeProvenance){$image.originalRuntimeProvenance=@{proxySourceCommit=$image.proxySourceCommit;integratedUpstreamCommit=$image.integratedUpstreamCommit;proxyBinarySha256=$image.proxyBinarySha256;clientBinarySha256=$image.clientBinarySha256;clientSettingsSha256=$image.clientSettingsSha256}}
$image.proxySourceCommit=$runtime.sourceCommit
$image.integratedUpstreamCommit=$runtime.integratedUpstreamCommit
$image.proxyBinarySha256=$runtime.candidateSha256
$image.clientBinarySha256=$client.sha256
$image.clientSettingsSha256=Hash 'C:\Users\darka\.claude\settings.json'
$image.rollback=$image.rollback.Clone()
$image.rollback.restoreScript=Join-Path $RecoveryDirectory 'restore-integration.ps1'
$image.rollback.restoreScriptSha256=Hash $image.rollback.restoreScript
$image.rollback.frozenConfigurationHelper=$package.helper
$image.rollback.frozenLifecycle=$package.lifecycle
$image.rollback.recoveryRuntimeManifest=$package.runtimeManifest
$image.rollback.recoveryPackage=$packagePath
$image.rollback.procedure="At fresh idle validate with restore-integration.ps1 -RecoveryPackage $packagePath -ValidateOnly; remove -ValidateOnly to restore only the owned integration. Qualified current runtime and original activation/config proof are both required."
$image.recoveryVerification=@{passed=$true;at=[DateTime]::UtcNow.ToString('o');package=$packagePath;liveRestoreExecuted=$false;fixtures=$FixtureResult}
Save $image (Join-Path $RecoveryDirectory 'image-active-staged.json')
$cm=Read $client.manifest
# A proxy activation legitimately changes build provenance. Verify its prior
# binding against the preceding qualified recovery package before advancing it.
$provenance=Join-Path $runtime.installDirectory 'build-info.json'
foreach($f in $cm.protectedFiles){
 if($f.path -eq $provenance -and $f.sha256 -ne $runtime.expectedInstalledBuildInfoHash){
  if(-not $priorRecoveryPackage){throw 'Prior qualified runtime binding required'}
  $priorPackage=Read $priorRecoveryPackage
  if((Hash $priorPackage.runtimeManifest) -ne $priorPackage.runtimeManifestSha256){throw 'Prior runtime manifest changed'}
  $priorRuntime=Read $priorPackage.runtimeManifest
  if($f.sha256 -ne $priorRuntime.expectedInstalledBuildInfoHash){throw 'Unexpected prior client provenance binding'}
  $f.sha256=$runtime.expectedInstalledBuildInfoHash
 }
}
# Only the integration's authorized recovery metadata changed. Keep every other
# protected digest, installed pair and original activation receipt intact.
$matches=0
foreach($f in $cm.protectedFiles){if($f.path -eq $ImageActive){if($f.sha256 -ne $imageHash){throw 'Client integration baseline changed'};$f.sha256=Hash (Join-Path $RecoveryDirectory 'image-active-staged.json');$matches++}}
if($matches -ne 1){throw 'Exact ImageGen protected baseline missing'}
$cm.receiptPath=Join-Path $RecoveryDirectory 'client-restore-receipt.json'
$clientManifest=Join-Path $RecoveryDirectory 'client-recovery-manifest.json'
Save $cm $clientManifest
$package.clientRecoveryManifest=$clientManifest
$package.clientRecoveryManifestSha256=Hash $clientManifest
$package.clientDeployer=Join-Path $client.releaseDirectory 'maintenance\deploy-client.ps1'
$package.clientDeployerSha256=Hash $package.clientDeployer
Save $package $packagePath
if(-not $client.originalActivationManifest){$client.originalActivationManifest=$client.manifest}
$client.manifest=$clientManifest
$client.restoreScript=Join-Path $RecoveryDirectory 'restore-client.ps1'
$client.recoveryBinding=@{manifest=$clientManifest;manifestSha256=(Hash $clientManifest);deployer=(Join-Path $client.releaseDirectory 'maintenance\deploy-client.ps1');originalActivationReceipt=$client.receipt;restoreMode='Restore';validateMode='Verify';procedure='At fresh idle invoke the frozen deployer with this bound manifest and -Mode Restore; Verify checks current installed/protected state without changes.'}
$client.imageIntegration.recoveryPackage=$packagePath
$client.imageIntegration.proxySourceCommit=$runtime.sourceCommit
$client.imageIntegration.proxyBinarySha256=$runtime.candidateSha256
$client.recoveryBinding.restoreScript=$client.restoreScript
$client.recoveryBinding.restoreScriptSha256=Hash $client.restoreScript
$client.recoveryBinding.procedure="At fresh idle run restore-client.ps1 -RecoveryPackage $packagePath; add -ValidateOnly for current installed/protected checks without changes."
if((Hash $ImageActive) -ne $imageHash -or (Hash $ClientActive) -ne $clientHash){throw 'Concurrent active-state writer'}
[IO.File]::Replace((Join-Path $RecoveryDirectory 'image-active-staged.json'),$ImageActive,[NullString]::Value)
Save $client (Join-Path $RecoveryDirectory 'client-active-staged.json')
[IO.File]::Replace((Join-Path $RecoveryDirectory 'client-active-staged.json'),$ClientActive,[NullString]::Value)
& $client.recoveryBinding.deployer -ManifestPath $clientManifest -Mode Verify
Save @{passed=$true;at=[DateTime]::UtcNow.ToString('o');originalActivationManifest=$originalManifest;originalActivationReceipt=$image.activationReceipt;imageActiveSha256=(Hash $ImageActive);clientActiveSha256=(Hash $ClientActive);package=$packagePath;clientRecoveryManifest=$clientManifest;configurationChanged=$false;processRestarted=$false;liveRestoreExecuted=$false} (Join-Path $RecoveryDirectory 'verification.json')
Write-Output 'Current client and ImageGen recovery contracts verified; original activation evidence and live service preserved.'
}finally{if($proxyHeld){$proxyMutex.ReleaseMutex()};if($clientHeld){$clientMutex.ReleaseMutex()};$proxyMutex.Dispose();$clientMutex.Dispose()}
