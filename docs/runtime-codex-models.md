# Runtime Codex model catalog

Authorization: user requested runtime model configuration and Codex discovery.

Requirements:
- Replace duplicated Rust model tables with one JSON default catalog.
- Read config-directory codex-models.json at runtime; entries specify id and
  responsesLite, and an optional codexCachePath imports Codex's model cache.
- Import visible GPT model entries with explicit use_responses_lite metadata;
  exclude hidden/reserved entries. Manual entries override discovery metadata.
- The running proxy must update listing, routing, validation, fast variants and
  Responses Lite selection consistently, without restart or recompilation.
- Retain last valid data on invalid updates; preserve aliases, current defaults,
  WebSocket and compaction behavior. Catalog refresh must not launch Codex or
  network requests in the inference path.
- Provide a command/script to explicitly refresh the cache using Codex's
  authenticated debug models command, without another OAuth login.

Stages:
1. COMPLETE: catalog loader, regression tests, and integration across all APIs.
   Verified hot addition/removal, last-good handling, discovery metadata,
   routing, fast variants, native and Chat Completions translation. Full
   regression suite passed; library suite also passed after making an existing
   keepalive test deterministic with the same Tokio clock as its protocol timer.
2. COMPLETE: build, isolated runtime/live verification, installation and
   deployment at an idle boundary, final verification, commit and cleanup.
   Build and isolated runtime verification passed: a running candidate imported
   Daybreak, excluded reserve, hot-added a manual model and fast variant, routed
   count_tokens, and hot-removed it with the same PID. Real Sol 6.1 inference
   returned HTTP 200 and message_stop over WebSocket/Responses Lite.
   Installed the JSON discovery configuration and refresh helper. Candidate
   binary was deployed on 2026-10-02 as compaction4.catalog1 together with the
   compaction preparation heartbeat fix. Installed hash/version and live health
   verified; live catalog imports Daybreak and Sol 6.1, excludes reserve. Ordinary
   Sol 6.1 inference returned 200/message_stop; logs confirm WebSocket transport.

Acceptance: add a future model via JSON and observe routing/listing without
restarting; import only visible models and correct Lite metadata; malformed
updates preserve last good data; all request APIs use the shared catalog;
Sol 6.1 streamed live inference still succeeds.

Safe deployment criterion satisfied: user paused ClaudeGPT; monitor reported zero
active requests before stopping only the owned supervisor. All deployment steps
were separately accepted by execution policy. Model/provider/OAuth configuration
and Claude settings were preserved. All required verification is satisfied;
no blockers or tracked deferrals. Catalog implementation commit 0806b61 is included
in deployed implementation commit 60a127a. Expendable release output was cleaned.

Staging/recovery directory:
`C:/Users/darka/AppData/Local/Programs/claude-code-proxy/staging/v0.1.42-pr158.compaction4.catalog1`.
Candidate SHA-256: `61C1D1765A58EAC2178D8B15B2B17E21E7A557DD0023D1CDB02BDAFB6EAF5454`.
Rollback: stop the supervisor, restore claude-code-proxy.rollback.exe as the
installed claude-code-proxy.exe and build-info.rollback.json as build-info.json,
then relaunch start-hidden.vbs. Old binaries ignore the separate catalog file.

## Configuration and refresh

Create `codex-models.json` in the proxy configuration directory (`CCP_CONFIG_DIR`)
with a cache path and optional manual additions:

```json
{
  "codexCachePath": "C:/Users/darka/.codex/models_cache.json",
  "models": []
}
```

Manual entries have the form `{"id":"gpt-future-sol","responsesLite":true}`.
Only use real upstream model IDs and verified lane metadata. Base IDs generate
their `-fast` variants automatically; `[1m]` remains a client hint. IDs must be
GPT base IDs, not fast variants, aliases or provider-prefixed IDs. Duplicate
manual IDs and missing lane metadata invalidate the entire update.

Precedence is manual entries > visible Codex cache entries > bundled JSON
defaults. Hidden entries are not imported. Defaults preserve legacy access.
Files reload when modification time or size changes; use atomic replacement for
updates. Invalid or missing files retain last-good data during the process
lifetime. Removing `codexCachePath` disables discovery. A missing/invalid file
at startup uses bundled defaults, with a warning for invalid files.

Run `scripts/refresh-codex-models.ps1` to query the authenticated Codex CLI and
refresh its cache. The proxy itself never invokes a subprocess or network
refresh while serving inference. No restart is needed for catalog changes.
Discovery adds available choices; it does not change Claude's selected/default
model or guarantee account inference access. New upstream protocols may still
need a proxy code update.
