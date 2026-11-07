# GPT-6.1 Sol support

Authorization: user requested implementation, proxy restart, and GPT-6.1 default.

Requirements: register gpt-6.1-sol and its fast variant; permit the exact base
model upstream; use Responses Lite like existing Sol models; preserve existing
WebSocket/compaction recovery; set Claude's main Opus/custom model to 6.1 Sol,
preserving helper models and reasoning effort. Verify real streamed inference.

Stages:
1. COMPLETE: routing/allowlist/Lite regression tests failed before the patch and
   pass after it. All 927 library tests pass serially. Corrected a pre-existing
   stale test expectation for Luna 6; the timing test passes in isolation.
   Release build 0.1.42-pr158.compaction3.sol61 succeeded.
2. COMPLETE: installed binary hash verified, proxy restarted on 127.0.0.1:8317,
   deployed GPT-6.1 Sol streamed HTTP 200 over WebSocket and reached message_stop.
   Claude main model, Opus environment alias, and custom selector use
   gpt-6.1-sol[1m]; high effort and helper models preserved. Source committed
   after fresh formatting/diff checks. Existing Claude sessions can explicitly
   select /model gpt-6.1-sol[1m].

Candidate on port 18317: gpt-6.1-sol[1m] streamed HTTP 200 over WebSocket,
Responses Lite enabled, text OK and terminal message_stop received.

Rollback: stop via installed stop-proxy.ps1, restore binary/build-info and Claude
settings from staging/v0.1.42-pr158.compaction3.sol61, then start-hidden.vbs.

No blockers or tracked deferrals.
