param(
    [string]$CodexExecutable = $(if ($env:CODEX_CLI_PATH) { $env:CODEX_CLI_PATH } else { 'codex' }),
    [string]$CodexDirectory = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' })
)
$ErrorActionPreference = 'Stop'
# The official CLI refreshes its authenticated account catalog and models_cache.json.
# Capture the catalog so model instructions are never printed to the terminal/log.
$oldCodexDirectory = $env:CODEX_HOME
try {
    $env:CODEX_HOME = $CodexDirectory
    $raw = & $CodexExecutable debug models
    if ($LASTEXITCODE -ne 0) { throw "Codex catalog refresh failed (exit $LASTEXITCODE)." }
    $catalog = ($raw -join [Environment]::NewLine) | ConvertFrom-Json
    if (-not $catalog.models) { throw 'Codex returned an empty model catalog.' }
    $cachePath = Join-Path $CodexDirectory 'models_cache.json'
    if (-not (Test-Path -LiteralPath $cachePath)) { throw "Codex model cache was not written: $cachePath" }
    [pscustomobject]@{
        CachePath = $cachePath
        VisibleModels = @($catalog.models | Where-Object { $_.visibility -eq 'list' } | ForEach-Object { $_.slug })
    }
} finally {
    $env:CODEX_HOME = $oldCodexDirectory
}
