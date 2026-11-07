#Requires -Version 7.4
param([Parameter(Mandatory)][string]$RecoveryPackage,[switch]$ValidateOnly)
$ErrorActionPreference='Stop'
$r=Get-Content -LiteralPath $RecoveryPackage -Raw|ConvertFrom-Json -AsHashtable
if((Get-FileHash $r.clientRecoveryManifest).Hash.ToLowerInvariant() -ne $r.clientRecoveryManifestSha256){throw 'Client recovery manifest changed'}
if((Get-FileHash $r.clientDeployer).Hash.ToLowerInvariant() -ne $r.clientDeployerSha256){throw 'Frozen client deployer changed'}
$mode=if($ValidateOnly){'Verify'}else{'Restore'}
& $r.clientDeployer -ManifestPath $r.clientRecoveryManifest -Mode $mode
