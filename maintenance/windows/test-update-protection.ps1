param(
    [string]$Updater = (Join-Path $PSScriptRoot 'update-proxy.ps1'),
    [string]$VersionExecutable
)
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Updater, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw "Updater parse errors: $parseErrors" }
$function = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Get-StockUpdateBlockReason'
}, $true)
if (-not $function) { throw 'Missing protection: stock updater can replace a patched build.' }
Invoke-Expression $function.Extent.Text
$hash = 'A' * 64
$stock = [pscustomobject]@{
    repository = 'https://github.com/raine/claude-code-proxy'
    build_kind = 'official Windows amd64 release'
    binary_sha256 = $hash
}
$cases = @(
    @{name='custom suffix';version='0.1.42-pr158.stream1.catalog1.provenance1.noop1';info=$stock;hash=$hash;blocked=$true},
    @{name='legacy fork provenance';version='0.1.45';info=[pscustomobject]@{repository='https://github.com/Darkaxt/claude-code-proxy'};hash=$hash;blocked=$true},
    @{name='current fork provenance';version='0.1.45';info=[pscustomobject]@{sourceRepository='https://github.com/Darkaxt/claude-code-proxy'};hash=$hash;blocked=$true},
    @{name='missing provenance';version='0.1.45';info=$null;hash=$hash;blocked=$true},
    @{name='empty provenance';version='0.1.45';info=[pscustomobject]@{};hash=$hash;blocked=$true},
    @{name='unrecognized version';version='not-a-version';info=$stock;hash=$hash;blocked=$true},
    @{name='changed executable';version='0.1.45';info=$stock;hash=('B'*64);blocked=$true},
    @{name='verified official';version='0.1.45';info=$stock;hash=$hash;blocked=$false},
    @{name='contradictory provenance';version='0.1.45';info=[pscustomobject]@{repository=$stock.repository;build_kind=$stock.build_kind;binary_sha256=$hash;sourceRepository='https://github.com/Darkaxt/claude-code-proxy'};hash=$hash;blocked=$true}
)
foreach ($case in $cases) {
    $reason = Get-StockUpdateBlockReason -PackageVersion $case.version -BuildInfo $case.info -InstalledHash $case.hash
    if ([bool]$reason -ne $case.blocked) { throw "Wrong protection result: $($case.name) ($reason)" }
    Write-Output "PASS $($case.name)"
}
if ($VersionExecutable) {
    $versionFunction = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-InstalledPackageVersion'
    }, $true)
    Invoke-Expression $versionFunction.Extent.Text
    $executable = $VersionExecutable
    $fullVersion = Get-InstalledPackageVersion
    if ($fullVersion -notmatch '^\d+\.\d+\.\d+(?:-\S+)?$') { throw 'Native version extraction failed' }
    Write-Output "PASS native executable version: $fullVersion"
}
