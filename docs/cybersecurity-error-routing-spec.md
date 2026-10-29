# Structured cybersecurity refusal routing

Authorization: user's 2026-10-29 request to route the newly observed cybersecurity
advisory through the existing cyber_policy flow. This does not request Daybreak,
new credentials, enrollment, access-program changes or refusal suppression.

## Requirements

- C1: Keep explicit upstream cyber_policy handling. In a structured failure
  envelope only, also recognize an error.message beginning with either exact
  established sentence: `This content was flagged for possible cybersecurity risk.`
  or `This request has been flagged for possible cybersecurity risk.` Leading
  whitespace is allowed. This bounded match handles the observed advisory when
  its string code is unknown or absent. Never classify recorder `other` alone,
  arbitrary mentions, quoted text, generated deltas or unrelated errors as cyber.
- C2: Route this classification through the same permanent/nonretryable,
  same-owner pending-notice path across HTTP JSON/SSE and WebSocket, buffered and
  streaming, before/after output as applicable. Preserve the upstream message
  and explicit status. Without an explicit status, use the existing policy 400.
  Keep x-should-retry=false and prevent auth-refresh/fallback/automatic replays.
- C3: The diagnostic notice reports a normalized cybersecurity classification,
  not a falsely asserted original code. Keep its existing same-owner, compaction,
  cancellation, stale-success, bounded metadata and next-existing-turn semantics.
  It neither creates a turn nor grants eligibility nor repeats rejected work.
- C4: Keep recorder privacy and bounds. Preserve the literal known cyber_policy
  code in its safe code allowlist and record the shared boolean classification
  for message-recognized errors; unknown codes remain other. Do not persist raw
  error messages, requests, arbitrary codes or credentials.
- C5: Verify fictional local regressions and the complete original
  error -> refusal -> next existing matching-owner turn -> guidance -> successful
  acknowledgement workflow; sibling-owner and unrelated-text negatives remain.
  No real upstream request or original Skyrim operation is replayed.
- C6: Deliver a versioned optimized Windows fork release, normally commit/push
  the existing fork branch, preserve the maintained dirty specification, and
  activate only through the existing safe-consumer deployment transaction.
  Verify actual installed hash/version/provenance, owned process/listener,
  health/catalog/protected settings and recovery environment. Preserve one
  usable rollback. Clean exact task scratch transactionally after last use.
  Authorized 2026-10-29 delivery update: the user explicitly paused both client
  threads and instructed deployment with those clients open. Support that scoped
  restart boundary in the existing deployer using a hash-bound pause statement,
  exact complete client PID/start/path identities and connection-peer ownership.
  Preserve the default closed-client requirement, active-request refusal, fresh
  repeated checks, mutex, protected state, owned lifecycle and rollback behavior.
  Wrapper-only changes reuse the unchanged verified runtime candidate.

## Stages

1. Integrated routing and qualification — COMPLETE. C1-C5; complete shared
   classification, notice/recorder wiring, regressions, release build and isolated
   startup. Verified by focused Codex regressions, the HTTP/WebSocket buffered and
   streaming policy matrix, cutover checks, installed ledger fixture, stock-updater
   guard, formatting, optimized two-job Windows build and isolated startup/exit.
   No blockers or tracked deferrals. Shared classification remains the single
   policy decision; scope review found no required consolidation.
2. Final local delivery — ACTIVE. C6; depends on stage 1. This is the sole
   final release/activation stage. Existing consumer ambiguity parks activation
   without stopping active work; retained candidate remains an incomplete delivery.

The private current reconciliation ledger and exact scripts/evidence are under
`D:/Tools/claudegpt-maintenance/run-20261029-cyber-routing`. No incidental dirty
file, runtime/provider setting, other task or speculative feature is in scope.
