# Policy-interruption replanning and approach ledger

## Authorized scope and requirements

The user approved generic safe replanning with an approach ledger, not automatic
retries of policy blocks. The supplied `approach-recovery-ledger` v0.1.0 skill and
its entry/integration contracts govern ledger use. Prepare and verify the feature;
do not install the skill, change live settings/models, or deploy/restart the proxy.

- R1: Preserve `cyber_policy` as a visible, non-retryable upstream interruption.
  Do not fabricate success, hide the refusal, resubmit blocked operations, or
  infer which operation caused it. Preserve completed tool results.
- R2: On a later client-submitted, non-compaction request, including an existing
  Goal-generated automatic continuation (no manual resume required), attach a clearly
  attributed diagnostic note only to the same typed conversation owner (session
  and agent). This is not new human authorization. The proxy never creates the
  next request. No note for an unknown/invalid owner or a mere textual mention.
  Existing Goal attempt limits are unchanged; a wakeup is not new authority and
  must not override a ledger-backed pause/no-permitted-alternative decision.
  Utility-only standalone search does not consume a notice; it remains pending
  for the next ordinary agent-generation turn.
- R3: Keep pending observations bounded to 256 owners, containing only a notice
  ID, request correlation and UTC receipt time, not prompts, errors or plans.
  Retain a notice across cancellation/transport failures. A successful terminal
  response acknowledges only the notice actually attached to that request;
  an older response must not clear a newer interruption. No expiry/retry timers.
  Pending notices are in-memory; durable plan history belongs to the skill.
- R4: The generic note requires the agent to inspect its authoritative scope,
  last persisted plan, actual results and relevant shared history; record its
  actual execution plan and interruption using the skill; inspect the receipt;
  justify a materially different permitted approach or pause. No guessed trigger,
  private reasoning dump, cosmetic retry or weakened acceptance criteria.
- R5: Follow the skill's immutable linked-history, timestamp, context and criteria
  contracts. Completed tool calls remain completed. Unknown model/program/time
  evidence stays unknown. Later source-only work cannot supersede native proof.
  The proxy does not write guessed ledger entries on an agent's behalf.
- R6: The note names the skill. An optional process-local
  `CCP_APPROACH_RECOVERY_SKILL_PATH` selects a readable source/installed SKILL.md;
  no default machine-specific path is compiled into the public source. Missing
  skill/helper or failed writes must be reported and the record remains pending.
- R7: Verify with fictional upstream interruptions and an isolated ledger using
  the supplied helper. Do not provoke real safety checks or change access modes.
  Distinguish verified instruction delivery/helper behavior from unverified live
  model compliance. Preserve the previous staged recorder build and live state.

## Stages and reconciliation

1. Integrated replanning feature — COMPLETE
   Acceptance: R1-R6 fully wired for Codex Messages HTTP/WebSocket, streaming and
   buffered errors; owner isolation, terminal acknowledgement, cancellation and
   compaction boundaries verified; original retry/streaming tests unaffected.
   Verified: fictional HTTP/WebSocket x buffered/streaming next-turn delivery,
   before/after-semantic policy failures and HTTP 500 JSON policy failures;
   sibling-agent isolation, unchanged error messages, no proxy retry and explicit
   x-should-retry=false; successful delivery acknowledgement. Replanning unit
   checks verify cancellation/transport retention, compaction exclusion, stale
   success protection, unknown owners/text negatives and the 256-owner bound.
   Existing Codex provider regression checks and all 67 cutover smoke checks pass.
   R4-R6 are instruction-delivery contracts, not proof of live model compliance.
   Refactoring assessment: one metadata-only state owner, no retry scheduler or
   duplicated ledger implementation; no required consolidation finding.
   Blockers: none. Tracked deferrals: none.
2. Verify and prepare candidate — COMPLETE
   Acceptance: final R1-R7 reconciliation, fictional cross-thread ledger fixture, focused regression
   checks, build/version/provenance verification, local commit and candidate
   staging complete; expendable scratch cleaned; no live deployment performed.
   Verified: installed Codex and Claude skill/helper parity and isolated ledger
   fixtures; final 14-case policy delivery matrix, including HTTP JSON 500/401
   and WebSocket 401 events; ordinary HTTP token refresh regression; optimized
   build and isolated startup/health on port 25136 with owned process exit.
   Final policy-coded 401 authentication-refresh gaps were corrected and verified.
   Candidate: `0.1.42-pr158.stream1.catalog1.provenance1.noop1.recorder1.replan1`,
   SHA-256 `4138413176450D6A9192F688B8EFD5E04D0441DAFE5C40B46CE39F279A5ACBCC`.
   Reviewed cleanup transaction `fa6b7f26bb97802951abb6195242997e` applied all
   3242 exact task-generated members without errors; source, staged candidates
   and unrelated development cache retained. Live binary/configuration unchanged.
   Source committed as `c664536153eb2ee204e0e09504e6fe4cc511f607`.
   Staged build-info was read back and matched the candidate hash, size and
   source commit. The original live PID 65424, binary/config/settings hashes
   and prior staged recorder1 candidate were reverified unchanged.
   Final reconciliation: R1-R7 satisfied within prepare-only scope. No blockers
   or tracked deferrals. No further consolidation is required; state ownership
   and ledger responsibility remain explicit. No deployment or publication.

No tracked deferrals. Ledger installation and live activation are outside this
approved prepare-only scope, not claims of delivered live behavior.

## Operational use and limits

The agent environment must have `approach-recovery-ledger` available. An optional
process-local `CCP_APPROACH_RECOVERY_SKILL_PATH` can point to its readable
`SKILL.md`; otherwise the note names the installed skill for normal discovery.
The proxy does not execute the helper, install skills, edit Claude settings,
change models/access programs, create Goal wakeups, or increase attempt limits.

Only the latest pending observation for each validated session/agent is retained.
At 256 owners, a new owner is not admitted and a capacity warning is logged;
existing notices are not evicted. No raw error, prompt, execution plan or hidden
reasoning is cached. The note carries validated ownership, observation ID,
request correlation and proxy receipt time. Original message/model/program/time
evidence not available to the recovered agent must remain explicitly unknown.

Pending notices do not survive a proxy restart. Terminal success acknowledges
delivery of one notice, not a ledger write or model compliance. The recovered
agent owns record accuracy, helper receipts and any ledger-backed pause. This
is guidance integration, not an enforced policy-recovery scheduler or a fix for
upstream policy decisions. Real live-agent compliance has not been tested.

Reproduce the local, fictional integration checks with:

```text
cargo test --test approach_replanning
cargo test --lib replanning
python -B scripts/verify_approach_ledger.py --skill-path <installed-SKILL.md> --scratch <new-exact-task-scratch-directory>
```

The helper fixture checks a completed read followed by a fictional interruption,
cross-process lookup, immutable IDs and criteria-preserving supersession. It
never invokes a model or provokes an actual policy rejection. The caller owns
reviewed cleanup of the exact scratch directory. Keep real ledgers outside Git.
