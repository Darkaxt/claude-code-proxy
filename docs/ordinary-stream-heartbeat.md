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
2. COMPLETE: R6 release build, isolated candidate verification, implementation
   commit f8eb4f5, confirmed-pause deployment and live verification passed.
   Installed binary and preserved configuration hashes were rechecked after
   transactional cleanup; healthz remains healthy. Recovery deliverables remain
   available, and all reviewed cleanup tickets reached applied without errors.

Blockers: none. Deferrals: none.
The user confirmed all threads safely paused on 2026-10-03; monitor verified
zero active requests, rechecked immediately before replacement. No additional
pause confirmation was required.

Candidate verification: Windows release 0.1.42-pr158.stream1.catalog1, SHA-256
477571223C324D7E18846FEE04B0B7CDA8658C2BF41943B8EA3F139F8D8BA601.
On isolated port 18317, real Sol 6.1 ordinary inference returned headers in
110 ms and the first ping in 121 ms, text and one message_stop in 4557 ms.
Logs confirm ordinary upstream transport websocket. Native compaction returned
headers in 12 ms and first ping in 13 ms, text and one message_stop in 13494 ms.
Health/catalog passed; both requests completed without error. Candidate process
was stopped only after its requests completed. Configuration, Claude settings,
and manual catalog SHA-256 hashes are unchanged.

Live deployment on 2026-10-03: zero active requests rechecked immediately before
stopping only the owned proxy child and supervisor (92156/78108). Staged candidate and
prior binary/build-info retained under
`C:/Users/darka/AppData/Local/Programs/claude-code-proxy/staging/v0.1.42-pr158.stream1.catalog1/`.
Installed version and SHA-256 match the tested candidate. Existing hidden launcher
started owned process 29200 under supervisor 48900; startup scripts are unchanged.
Real ordinary inference returned HTTP 200 headers in 152 ms, initial ping in
165 ms, text and one message_stop in 3517 ms; log confirms transport websocket.
Native compaction returned headers in 11 ms, initial ping in 12 ms, text and one
message_stop in 17839 ms. Health/catalog passed, both monitor entries completed
without error, and config/settings/manual-catalog hashes match pre-deployment.
The user was notified that paused threads may now continue. This verifies the
gateway fix and deployment, not completion of Navic's original implementation.
Generated expendable outputs: Cargo target outputs created by this task and
isolated verification artifacts. The candidate/rollback files are intentional
recovery deliverables; existing source, cached artifacts, auth and user files
are preserved. Cleanup uses a scoped transactional snapshot of target.

Cleanup reconciliation: transaction 12de33916d7128cda91520c449b6f1bf deleted
the ordinary newly generated build outputs (7,621,232,322 reported file bytes).
It initially preserved Cargo hard-linked names, leaving nonempty directories.
The exact release folder and four newly generated incremental-cache directories
were independently attributed to this task and reviewed in follow-up transactions
3703f73468d3fabdc3943a42b4531e6a and 54bfa824d54917b89a4ea3a430183190.
Only those registered names were removed with explicit hard-link handling; other
link names, pre-existing cache, source, installed files and rollback remain intact.
Both follow-up tickets and the original retried ticket are applied with no errors
or remaining candidate members. Reported file-byte totals for hard links are not
a measurement of physically reclaimed disk space. Verification evidence and the
candidate/rollback files remain intentional diagnostic/recovery outputs.
