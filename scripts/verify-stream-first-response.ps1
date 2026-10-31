param(
    [string]$BaseUrl = 'http://127.0.0.1:18317',
    [switch]$IncludeCompaction
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

function Test-StreamingRequest([bool]$Compact) {
    $sessionId = [guid]::NewGuid().ToString()
    $payload = @{
        model = 'gpt-6.1-sol[1m]'
        max_tokens = 64
        stream = $true
        messages = @(@{ role = 'user'; content = 'Reply with exactly READY.' })
    }
    if ($Compact) {
        $payload.system = 'You are a helpful AI assistant tasked with summarizing conversations.'
        $payload.messages = @(@{ role = 'user'; content = 'The user wants a short verification that the proxy can compact a conversation.' })
    }
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$BaseUrl/v1/messages")
    $request.Headers.Add('anthropic-version', '2023-06-01')
    $request.Headers.Add('x-claude-code-session-id', $sessionId)
    $request.Content = [System.Net.Http.StringContent]::new(($payload | ConvertTo-Json -Depth 8 -Compress), [System.Text.Encoding]::UTF8, 'application/json')
    $response = $null
    $reader = $null
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $headerMs = $clock.ElapsedMilliseconds
        if ([int]$response.StatusCode -ne 200) { throw "Unexpected HTTP status: $([int]$response.StatusCode)" }
        if ($response.Content.Headers.ContentType.MediaType -ne 'text/event-stream') { throw 'Expected SSE content type' }
        $reader = [System.IO.StreamReader]::new($response.Content.ReadAsStreamAsync().GetAwaiter().GetResult())
        $first = $reader.ReadLineAsync().GetAwaiter().GetResult()
        $firstMs = $clock.ElapsedMilliseconds
        if ($first -ne 'event: ping') { throw "Expected immediate ping, got: $first" }
        $stopCount = 0
        $sawText = $false
        while ($null -ne ($line = $reader.ReadLineAsync().GetAwaiter().GetResult())) {
            if ($line -eq 'event: error') { throw 'Upstream SSE error received' }
            if ($line -eq 'event: message_stop') { $stopCount++ }
            if ($line.StartsWith('data: ')) {
                $event = $line.Substring(6) | ConvertFrom-Json
                if ($event.type -eq 'content_block_delta' -and $event.delta.type -eq 'text_delta' -and $event.delta.text) { $sawText = $true }
            }
        }
        if ($stopCount -ne 1 -or -not $sawText) { throw "Missing output or terminal event (stops=$stopCount, text=$sawText)" }
        [pscustomobject]@{
            session_id = $sessionId
            compact = $Compact
            headers_ms = $headerMs
            first_ping_ms = $firstMs
            total_ms = $clock.ElapsedMilliseconds
            message_stop_count = $stopCount
            text_received = $sawText
        }
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($response) { $response.Dispose() }
        $request.Dispose()
        $client.Dispose()
    }
}

if (-not (Invoke-RestMethod "$BaseUrl/healthz").ok) { throw 'Proxy health check failed' }
$models = (Invoke-RestMethod "$BaseUrl/v1/models").data.id
if ($models -notcontains 'gpt-6.1-sol') { throw 'Sol 6.1 is missing from the catalog' }
Test-StreamingRequest $false | ConvertTo-Json -Compress
if ($IncludeCompaction) { Test-StreamingRequest $true | ConvertTo-Json -Compress }
