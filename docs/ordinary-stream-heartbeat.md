# Ordinary streaming first-response fix

Authorization: the user requested implementation and deployment after being
notified to safely pause other Claude threads. Do not replace the live proxy
until the user confirms that pause and the monitor shows zero active requests.

## Evidence and requirements

Navic's three ordinary WebSocket requests on 2026-10-03 were cancelled after
339-359 seconds without downstream headers or content. The installed Claude
client uses a separate first-response deadline of 300 seconds plus an upload
allowance, independently of API_TIMEOUT_MS=3000000. The provider holds headers
until semantic model output, whereas compact requests already stream pings
while awaiting preparation.

- R1: After existing local validation, ordinary streaming Codex requests return
  SSE headers and an immediate ping before awaiting upstream output. Reuse the
  existing 15-second heartbeat; no timeout extensions, arbitrary cancellation,
  new retries, or transport changes.
- R2: Forward translated model output exactly once and retain existing bounded
  recovery/no-replay-after-output rules. Keepalives are not model output.
- R3: Preserve upstream errors as SSE error payloads after headers. Local
  validation and nonstreaming status/body behavior remain unchanged.
- R4: Disconnect cancels pending preparation and releases request-owned state,
  without orphaned workers or invalidating newer continuation/compaction state.
- R5: Compaction, WebSocket, OAuth, chosen model, runtime catalog, and live
  configuration remain intact.
- R6: Stage a verified Windows binary, notify the user to pause, then replace
  only at the confirmed idle boundary. Verify health, real ordinary WebSocket
  inference, immediate headers/ping, and unchanged configuration; retain the
  prior binary and metadata for explicit rollback if live verification fails.

## Stages and reconciliation

1. COMPLETE: R1-R5. Reproduced withheld ordinary headers before the fix, then
   verified immediate ping before blocked WebSocket output, single output and
   terminal forwarding, disconnect cancellation (including unpolled state),
   330 seconds of virtual-clock keepalives, structured upstream SSE errors,
   bounded retries, and unchanged buffered/preflight HTTP errors. The full
   `cargo test --locked --all -- --test-threads=1` run passed on the current
   stream1.catalog1 source. Formatting and whitespace checks passed. Existing
   Windows-only unused-parameter warnings are unchanged and outside this fix.
2. ACTIVE: R6 release build and isolated candidate verification, commit,
   notification, confirmed-pause deployment and live verification. A staged
   candidate is not evidence of deployment or Navic recovery.

Blockers: none. Deferrals: none.
The user confirmed all threads safely paused on 2026-10-03; monitor verified
zero active requests. Recheck immediately before replacement. No additional
pause confirmation is required.

Candidate verification: Windows release 0.1.42-pr158.stream1.catalog1, SHA-256
477571223C324D7E18846FEE04B0B7CDA8658C2BF41943B8EA3F139F8D8BA601.
On isolated port 18317, real Sol 6.1 ordinary inference returned headers in
110 ms and the first ping in 121 ms, text and one message_stop in 4557 ms.
Logs confirm ordinary upstream transport websocket. Native compaction returned
headers in 12 ms and first ping in 13 ms, text and one message_stop in 13494 ms.
Health/catalog passed; both requests completed without error. Candidate process
was stopped only after its requests completed. Configuration, Claude settings,
and manual catalog SHA-256 hashes are unchanged.
Generated expendable outputs: Cargo target outputs created by this task and
isolated verification artifacts. The candidate/rollback files are intentional
recovery deliverables; existing source, cached artifacts, auth and user files
are preserved. Cleanup uses a scoped transactional snapshot of target.
