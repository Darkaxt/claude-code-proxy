# Compaction streaming lifecycle fix

Authorization: user requested a fix for compaction API errors and retry waiting.

Requirements and acceptance:
- R1: Streaming compact requests return SSE headers and an immediate ping before
  awaiting native compaction or summary generation. Reuse the existing heartbeat
  cadence throughout preparation; do not extend timeouts or add replay retries.
- R2: Forward the resulting SSE response unchanged. If preparation returns a
  JSON error after headers, send its error payload as an SSE error event.
- R3: Client disconnect cancels pending preparation and releases request state;
  no orphaned tasks or clearing newer session attempts.
- R4: Ordinary requests retain WebSocket, nonstreaming requests retain existing
  status/body behavior. Preserve OAuth, selected model, and runtime catalog.
- R5: Verify the reproduction, heartbeat, forwarding, error, and cancellation
  paths, then deploy the verified binary without cutting unrelated active work.

Stages:
1. COMPLETE: R1-R4 implementation and focused regression/integration verification.
   Reproduced withheld headers before fix; verified immediate ping, 330 seconds
   of virtual-clock heartbeats, summary forwarding, SSE error preservation,
   disconnect cancellation and attempt-scoped cleanup. Server integration proves
   headers/ping precede blocked native compaction. Full regression suite passed,
   including replay, nonstream error statuses and ordinary WebSocket transport.
2. BLOCKED: R5 release build, idle-boundary deployment, live verification,
   final reconciliation, commit and expendable-artifact cleanup.
   Release build and isolated real-account verification passed. Compact request
   returned HTTP 200 headers in 45 ms, first SSE event ping, then message_stop
   after 6.9 seconds. Full suite evidence applies to unchanged implementation;
   only package version metadata changed afterward and was verified in release.

External blocker: execution policy rejected the combined live deployment command
before any operation ran. R5 installed-proxy verification remains unsatisfied.
Resolving this requires an allowed live deployment execution path; do not bypass
the rejection with another shell or wrapper. Live proxy remains compaction3.sol61.
No deferrals. Existing catalog commit 0806b61 is included in the new binary;
its already verified runtime configuration remains unchanged.

Tested candidate retained at:
`C:/Users/darka/AppData/Local/Programs/claude-code-proxy/staging/v0.1.42-pr158.compaction4.catalog1/claude-code-proxy.candidate.exe`
SHA-256: `61C1D1765A58EAC2178D8B15B2B17E21E7A557DD0023D1CDB02BDAFB6EAF5454`.
Deployment must verify zero active requests, preserve current binary/build-info
for rollback, stop only the owned supervisor, replace the installed binary,
relaunch the existing hidden launcher, and verify live health/catalog/compaction.
If verification fails, stop the owned supervisor, restore the prior executable
and build-info, then relaunch. Configuration/OAuth/Claude settings must not change.
