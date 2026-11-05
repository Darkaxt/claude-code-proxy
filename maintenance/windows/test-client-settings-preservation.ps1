#Requires -Version 7.4
param([Parameter(Mandatory)][string]$QualifiedRelease,[Parameter(Mandatory)][string]$ProbeReceipt,[Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $FixtureRoot){throw 'Fixture destination already exists'}
New-Item -ItemType Directory $FixtureRoot|Out-Null
$real=Get-Content "$QualifiedRelease\candidate.json" -Raw|ConvertFrom-Json -AsHashtable
$results=@()
foreach($disabled in @($true,$false)){
 $case=Join-Path $FixtureRoot $(if($disabled){'already-disabled'}else{'enable-updater-guard'})
 $release=Join-Path $case 'release';$state=Join-Path $case 'state'
 New-Item -ItemType Directory $release,$state|Out-Null
 $candidate=@{}+$real
 $candidate.qualified=$false
 $candidate|ConvertTo-Json -Depth 64|Set-Content "$release\candidate.json" -Encoding utf8NoBOM
 foreach($name in @('payload-inspection.json','authorization-adaptation.json','authorization-probe.json','patched-version.log','prompt-apply.log')){Copy-Item -LiteralPath "$QualifiedRelease\$name" -Destination "$release\$name"}
 $settings=Join-Path $case 'settings.json'
 $guard=if($disabled){'1'}else{'0'}
 [IO.File]::WriteAllText($settings,"{`n  `"model`": `"fixture-model`",`n  `"env`": {`"DISABLE_AUTOUPDATER`": `"$guard`", `"OTHER`": `"preserve`"}`n}`n",[Text.UTF8Encoding]::new($false))
 $before=(Get-FileHash $settings).Hash
 $dummy=Join-Path $case 'dummy-installed.exe'
 [IO.File]::WriteAllText($dummy,'nonexecutable fixture bytes')
 & "$PSScriptRoot\finalize-client-candidate.ps1" -ReleaseDirectory $release -ProbeReceipt $ProbeReceipt -InstallBinary $dummy -SettingsPath $settings -StateDirectory $state -ProtectedPaths @($settings)
 $manifest=Get-Content "$state\deployment.json" -Raw|ConvertFrom-Json
 $after=(Get-FileHash $manifest.updatedSettingsPath).Hash
 if($disabled -and $before -ne $after){throw 'Already-enabled settings guard rewrote original bytes'}
 $expected=Get-Content $settings -Raw|ConvertFrom-Json -AsHashtable
 $expected.env.DISABLE_AUTOUPDATER='1'
 $actual=Get-Content $manifest.updatedSettingsPath -Raw|ConvertFrom-Json -AsHashtable
 if(-not [System.Text.Json.Nodes.JsonNode]::DeepEquals([System.Text.Json.Nodes.JsonNode]::Parse(($expected|ConvertTo-Json -Depth 12 -Compress)),[System.Text.Json.Nodes.JsonNode]::Parse(($actual|ConvertTo-Json -Depth 12 -Compress)))){throw 'Settings scope exceeded updater flag'}
 if((Get-FileHash $settings).Hash -ne $before){throw 'Input settings were modified'}
 $results+=@{case=$(if($disabled){'already-disabled'}else{'enable-updater-guard'});passed=$true;inputUnchanged=$true;onlyUpdaterGuardMayChange=$true;originalBytesPreserved=$disabled -and $before -eq $after;noLiveInstallationChanged=$true;realInference=$false}
}
$results|ConvertTo-Json -Depth 8|Set-Content (Join-Path $FixtureRoot 'results.json') -Encoding utf8NoBOM
$results|ConvertTo-Json -Depth 8
