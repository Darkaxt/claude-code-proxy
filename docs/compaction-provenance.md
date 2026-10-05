# Compaction instruction provenance

Authorization: user requested a fix for Navic's post-compaction self-summary
stops. Implement, verify, commit and prepare a binary; do not replace the running
proxy or change Claude settings, OAuth, models, WebSocket or timeout settings.

Evidence: the October 5 Navic auto-compaction summaries label Claude's synthetic
text-only/no-tools summary task as the current genuine user request. Subsequent
ordinary requests produce another summary and end_turn, with completed HTTP 200
responses. The proxy detects compact prompts in a recent eight-message tail but
removes them from native history only when the final translated item is a user
message. Appended context can therefore retain the maintenance instruction.

## Requirements and acceptance

- R1: Tell the portable summarizer that its synthetic maintenance request is not
  a human request and must not become the task to resume. Preserve real user
  instructions, unfinished work and genuine pause/approval boundaries. This
  maintenance response itself must stay text-only, with no callable tools.
- R2: Remove recognized synthetic compact text blocks throughout the recent
  translated message tail before native compaction and retained-history creation.
  Preserve adjacent text, images, function results, assistant quotations and
  historical messages outside the detection tail. Do not remove arbitrary prose.
- R3: Recognize Claude's exact leading compacted-history wrapper on ordinary
  requests and label its summary as historical model-generated context. Internal
  text-only/no-tools maintenance instructions quoted there are not active user
  instructions. Preserve the original summary, fresh requests and tool settings.
- R4: Regression tests must fail before implementation, then verify the actual
  translated wire requests and compaction/replay boundaries. Existing ordinary
  WebSocket, compact HTTP, streaming, error and cancellation behavior must pass.
- R5: Build and stage the replacement, verify with an isolated real-account
  continuation using synthetic data, reconcile and commit. Do not claim that the
  active Navic session is repaired or deploy without separate authorization.

## Stages

1. COMPLETE — R1-R3 reproduction and focused implementation. Acceptance: failing
   regressions inspected before production edits; all affected contracts pass.
   Three regressions failed for the expected missing behavior before edits. The
   focused patched run passes removal, adjacent text/image/function preservation,
   historical/assistant quotations, summary provenance, current pause preservation
   and unchanged non-Codex translation. Original payload text remains; ordinary
   turn tool settings remain, while maintenance turns explicitly disable tools.
2. COMPLETE — R4 integration/regression verification. Acceptance: in-process
   server tests inspect native/portable/ordinary upstream payloads, plus relevant
   existing provider/streaming tests and format checks.
   Verified upstream payloads exclude maintenance instructions from native
   history and replay, preserve the portable-summary request, and include current
   provenance guidance in the developer envelope. Portable-only continuation
   preserves a fresh genuine pause and its tools. A quoted-maintenance regression
   failed before tightening recognition to the exact prefix, then passed in the
   library regression run. Library and all smoke_cutover tests passed, including
   ordinary WebSocket, compact HTTP, stream headers/keepalives and cancellation.
   Format and whitespace checks pass. Eight pre-existing Windows unused-variable
   warnings remain outside this scope.
3. COMPLETE — R5 release, isolated model verification, staging and commit.
   Installed-binary isolated baseline reproduced a text-only summary/end_turn on
   the ordinary turn after native compaction. First candidate exposed a portable
   summarization regression: it attempted a tool call at the compact boundary.
   A new regression failed before enforcing the summarizer's explicit text-only
   response and disabling tool availability on both full and lite lanes. After
   correction, focused library compaction tests and compaction smoke tests pass;
   the native-history replay smoke was also verified with declared tools.
   The optimized locked release build and isolated real-account GPT-6.1 Sol high
   probe pass. All four synthetic cases pass: contaminated-summary continuation
   calls the inspection tool; a genuine pause calls no tools; internal compaction
   returns summary text/end_turn without tools; the subsequent native-compaction
   continuation calls the inspection tool instead of another summary.
   The inspection tool is declared, never executed. No real user task resumes.
   Original proxy PID 29200, installed binary, proxy configuration, Claude
   settings and OAuth hashes remain unchanged. WebSocket transport is preserved.
   Final candidate and before/after evidence are staged at
   `C:\Users\darka\AppData\Local\Programs\claude-code-proxy\staging\v0.1.42-pr158.stream1.catalog1.provenance1`.
   Candidate SHA-256:
   `C6820876D9B8A508718B1C99997B67235D90D7320D5E0E360ECB747EAFA5FE7D`.
   Task-owned isolated build/probe/auth-copy material and exact generated test
   binaries were removed using reviewed transactional-cleanup tickets. Source,
   shared pre-existing cache, staged deliverables and verification evidence remain.
   This document, production changes, regressions and probe are committed together.
   No deployment, proxy restart, global settings change, push or PR publication.

## Final reconciliation

R1: summary-only wire contract and genuine task provenance verified by failing
then passing regression and real-account probe. R2: stripped native history and
replay verified on wire, retaining adjacent content and historical quotations.
R3: ordinary history provenance and tool availability verified, including genuine
pause. R4: relevant broad provider/streaming suite passed before the final scoped
tool suppression; affected library and server-wire tests passed after it. R5:
release artifact and real-account before/after evidence retained, live state
unchanged, cleanup verified, completed scope committed. All required criteria
satisfied. No claim of deployed/live-session recovery is made.

Blockers: none. Tracked deferrals: none. Unit/payload verification does not prove
model behavior; isolated model verification does not prove live Navic recovery.
