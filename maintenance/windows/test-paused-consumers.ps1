#requires -Version 7.2
param([Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'deploy-fork.ps1')
if (Test-Path -LiteralPath $FixtureRoot) { throw 'fixture_must_be_new' }
[void][IO.Directory]::CreateDirectory($FixtureRoot)
$reviewPath=Join-Path $FixtureRoot 'consumer-review.json'
$script:clients=@([pscustomobject]@{Id=123;Path='C:\fictional\claude.exe';StartTime=[DateTime]::Parse('2026-10-29T10:00:00Z').ToUniversalTime()})
$script:active=@(); $script:connected=$false; $script:peer=123
# Boundary substitutions exist only in this isolated test process. Production
# admission calls the native process/socket/monitor APIs at every gate.
function Get-Process { [CmdletBinding()]param([string]$Name) $script:clients }
function Get-NetTCPConnection {
    [CmdletBinding()]param([int]$LocalPort,[int]$RemotePort,[string]$State)
    if (-not $script:connected) { return }
    if ($LocalPort -eq 8317) { [pscustomobject]@{LocalAddress='127.0.0.1';RemoteAddress='127.0.0.1';RemotePort=32123} }
    else { [pscustomobject]@{LocalAddress='127.0.0.1';RemoteAddress='127.0.0.1';OwningProcess=$script:peer} }
}
function Invoke-RestMethod { param($Uri,$TimeoutSec) @{snapshot=@{active=$script:active}} }
$m=@{consumerReviewPath=$reviewPath;baseUri='http://127.0.0.1:8317'}
$r=@{reviewed=$true;unresolvedConsumers=@()}
$script:checks=@()
function Save-Review { $r | ConvertTo-Json -Depth 6 | Set-Content $reviewPath; $m.consumerReviewSha256=Get-ForkHash $reviewPath }
function Reject([string]$Expected) {
    try { Assert-ForkConsumers $m; throw 'fixture_expected_refusal' }
    catch { if ($_.Exception.Message -ne $Expected) { throw }; $script:checks+=$Expected }
}
Save-Review
Reject 'claude_clients_active'
$r.userConfirmedPause=$true; $r.pauseScope='listed-clients-and-continuations'; $r.pauseAuthorizationSource='Fictional explicit owner pause'
$r.pausedClients=@(@{pid=123;executablePath='C:\fictional\claude.exe';started='2026-10-29T10:00:00Z';paused=$true})
Save-Review; Assert-ForkConsumers $m; $script:checks+='exact paused client admitted'
$script:connected=$true
Assert-ForkConsumers $m; $script:checks+='owned idle socket admitted'
$script:peer=456; Reject 'unreviewed_proxy_connection'; $script:peer=123
$script:active=@(@{requestId='fictional-active'}); Reject 'requests_active'; $script:active=@()
$r.pausedClients[0].started='2026-10-29T10:00:01Z'; Save-Review; Reject 'paused_client_identity_changed'
$r.pausedClients[0].started='2026-10-29T10:00:00Z'
$r.pausedClients[0].executablePath='C:\fictional\replacement.exe'; Save-Review; Reject 'paused_client_identity_changed'
$r.pausedClients[0].executablePath='C:\fictional\claude.exe'
$r.pausedClients[0].paused=$false; Save-Review; Reject 'paused_client_identity_changed'; $r.pausedClients[0].paused=$true
$script:clients+= [pscustomobject]@{Id=456;Path='C:\fictional\claude.exe';StartTime=[DateTime]::UtcNow}
Save-Review; Reject 'paused_client_set_changed'; $script:clients=@($script:clients[0])
$r.unresolvedConsumers=@('fictional background producer'); Save-Review; Reject 'consumer_review_unresolved'
$r.unresolvedConsumers=@(); Save-Review
'changed' | Add-Content $reviewPath; Reject 'consumer_review_changed'
Save-Review; Assert-ForkConsumers $m
$script:clients=@(); $script:connected=$false
$r=@{reviewed=$true;unresolvedConsumers=@()}; Save-Review; Assert-ForkConsumers $m
$script:checks+='default empty-client admission preserved'
@{ok=$true;checks=$script:checks;realInferenceRequests=0;liveProcessesModified=$false} | ConvertTo-Json -Depth 4
