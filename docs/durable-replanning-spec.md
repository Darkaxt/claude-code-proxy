# Durable recovery observations

Authority: user's 2026-10-29 go-ahead for restart-persistent pending notices and
observable queue/delivery acknowledgments after the replan2 investigation.
This specification supersedes the legacy volatile-state limitation recorded in
the earlier approach-replanning specification; that file has unrelated local work.

- D1: Persist pending notices before reporting them durable. Reload them after
  process restart. Keep one newest notice per exact validated session/agent
  owner, with the existing 256-owner capacity and no eviction of another owner.
- D2: Retain notices across compaction, cancellation, failed turns and stale
  success. Clear only the generation actually attached to a valid successful
  terminal response. Persist removal; a failed write must not falsely clear it.
- D3: Persist only domain-separated owner fingerprints, generated notice IDs,
  bounded request correlations and proxy observation times. No raw owners,
  prompts, source/tool contents, error messages, credentials or guessed plans.
  Use one bounded versioned snapshot and the existing atomic private JSON writer.
  Refuse malformed/oversize/unsupported state without overwriting that evidence;
  diagnose read/write failure while preserving the original API error.
- D4: Emit content-free correlated lifecycle events for queued, restored,
  attached and acknowledged observations; distinguish skipped ownership or
  compaction, capacity and persistence failures, and ignored stale acknowledgments.
  Attachment is instruction preparation, not proof of backend acceptance or an
  actual agent ledger write. No event claims such compliance.
- D5: Keep existing cyber_policy classification/refusal/nonretryable behavior,
  owner isolation, model/provider/OAuth settings, compaction/context recovery,
  output safeguards and Goal budgets. Never create a turn, replay a rejection,
  hide the refusal, execute a guessed agent plan or change access programs.
- D6: Verify the complete fictional error -> durable queue -> process exit ->
  reload -> matching next existing turn -> attachment -> successful acknowledgment
  -> restart with no redelivery. Include sibling/main isolation, stale success,
  failure/cancellation/compaction retention, corrupted/unwritable state, bounds
  and privacy. Retain affected HTTP/WebSocket integration and cutover checks.
  Do not provoke a real refusal or replay Skyrim. Legacy volatile notices cannot
  safely be reconstructed from owner-ambiguous historical captures; durability
  begins with new-version observations. The reported Skyrim interruption is
  already explicitly recorded as a diagnostic, not source-agent compliance.
- D7: Commit/push the existing fork branch, preserve unrelated dirty source,
  verify formatting and an optimized Windows release with at most two Cargo jobs,
  perform isolated startup, package with exact provenance, and use the checked-in
  deployment/rollback contract at a freshly verified safe consumer boundary.
  Independently verify installed state/environment and clean exact spent scratch.

## Stages

1. Durable workflow and qualification — COMPLETE: D1-D6, release build and
   isolated startup verified. Evidence covers the real child-process restart
   workflow, persistence/privacy/failure bounds, HTTP/WebSocket integration,
   existing cutover and ledger fixtures, formatting and optimized two-job build.
   The semantic-retry fixtures reuse the existing test-only delay control to
   avoid a deadline/backoff race; production timing is unchanged. No blockers,
   deferrals or required consolidation: the existing notice owner/mutex and
   atomic writer remain authoritative.
2. Final delivery — ACTIVE: D7; depends on stage 1. No intermediate release.

Current reconciliation is retained privately under
`D:/Tools/claudegpt-maintenance/run-20261029-durable-replanning/STATUS.md`.
