# Intentional silent wakeup completion

Authorization: already_authorized by the user's 2026-10-11 go-ahead.

## Evidence and scope

Thread Manager's successful `ScheduleWakeup(noop: true)` result explicitly
said there was nothing more to do this turn. Codex returned successful empty
terminal events; the proxy retried three times and surfaced a 503 twice.
Do not broadly accept empty responses after arbitrary tools (upstream PR #122).

## Requirements and acceptance criteria

- R1: Allow a successful empty Codex completion only when the original
  Anthropic request ends with a single successful result for the immediately
  preceding single `ScheduleWakeup` tool call, whose `noop` argument is the
  boolean true. Require the scheduling-success acknowledgement, matching call
  ID, and no additional user content or unresolved sibling tool calls.
- R2: Preserve normal output, errors, missing-terminal failures, continuation,
  usage accounting, WebSocket transport, and compaction behavior. Do not
  fabricate assistant text, add retries/timeouts, or change live configuration.
- R3: Exercise streaming and buffered paths. A regression must fail before the
  fix and pass afterwards; ordinary/error/mismatched/non-noop tool tails must
  retain the empty-response protection.
- R4: Verify our existing equivalent of upstream v0.1.44's exhausted-empty
  `x-should-retry: false` protection (commit 0ea44cae). Do not duplicate it or
  import unrelated ultrafast/model-default changes from v0.1.45.
- R5: Build a Windows release artifact, record its source and digest, commit
  verified changes and synchronize the integration branch to the existing
  public Darkaxt/claude-code-proxy fork. Do not create or rename another fork.
- R6: Do not interrupt running proxy consumers. Stage the artifact separately;
  live replacement requires a coordinated idle boundary and is not a claimed
  result of this implementation/package stage.

## Stages and reconciliation

1. COMPLETE — R1–R4: the four transport/response-mode regressions failed with
   the original empty-completion error before implementation and passed after
   it. The strict request-tail matrix rejects failed/malformed/mismatched
   results, ordinary tools, missing/non-boolean/false noop, additional user
   work and sibling tool calls. All 437 Codex provider checks and 57 Codex
   integration checks passed, including six negative-control executions and
   the existing exhausted-empty no-client-retry protection. Formatting and
   diff checks passed. Existing Windows-only unused-argument warnings remain
   unchanged; no unrelated warning cleanup was performed.
2. COMPLETE — R5–R6: the release candidate passed the recorded verification
   and its provenance was retained. Implementation commit
   `e197d538c8d73282838c1663c12f74ed90c693fc` was pushed to the public integration
   branch and independently verified with `git ls-remote`. The running proxy
   retained its original process identity, executable/config/settings digests
   and successful health check. Activation remains outside this package stage
   until the user coordinates an idle boundary.

## Upstream review (2026-10-11)

- Existing public fork: https://github.com/Darkaxt/claude-code-proxy
  (parent raine/claude-code-proxy). Integration branch:
  `fix/websocket-http-fallback`; the deployed patches were eight local commits
  ahead of its public tip at the start of this change.
- Latest upstream release v0.1.45 (2026-10-10) adds the opt-in ultrafast tier.
  Do not enable a different service tier or replace our patched build with a
  stock binary. The runtime model catalog already supports GPT-6.1 Sol.
- v0.1.44's PR #175 is behaviorally present locally already, including
  `x-should-retry: false` and regression coverage. No duplicate integration is
  needed. PR #178 proposes additional empty-retry logging; this build already
  records empty events, attempts and exhaustion.
- Open PR #122 accepts repeated successful empty completions after generic
  successful tool tails. That is broader than this task: retain our strict
  acknowledged `ScheduleWakeup(noop: true)` condition instead.

Blockers: none. Tracked deferrals: none.

Verification commands (2026-10-11):

```text
cargo test --locked --test smoke_cutover smoke_codex_noop_wakeup -- --test-threads=1
cargo test --locked --lib providers::codex:: -- --test-threads=1
cargo test --locked --test smoke_cutover smoke_codex -- --test-threads=1
cargo fmt --all --check
cargo clippy --locked --lib --jobs 2
cargo build --release --locked --jobs 2
git diff --check
```

## Packaged candidate verification

- Version: `0.1.42-pr158.stream1.catalog1.provenance1.noop1`.
- SHA-256: `A81FA5D3B4E8B3E1D997B2FA6E263A1107ABADBABFF04ACCE150318E4A2C7AB5`.
- Executable length: 20,171,264 bytes. Staged under the installed program's
  `staging/v0.1.42-pr158.stream1.catalog1.provenance1.noop1` directory.
- Release build and Clippy passed; the eight pre-existing Windows unused-variable
  warnings remain unchanged.
- The staged executable reported the expected version and served a successful
  isolated `/healthz` check on an OS-assigned port. Its monitor showed zero active
  requests. Only this owned verification child was stopped afterwards.
- No real inference request was sent during startup verification. Provider and
  protocol integration were exercised with deterministic local upstreams.
- The live proxy, OAuth state, WebSocket configuration, model catalog, Claude
  settings and watchdog were not changed. This candidate is not yet deployed.
- Build provenance is retained beside the staged executable in `build-info.json`;
  isolated startup diagnostics are intentional verification evidence.
- Transactional cleanup removed only reviewed, task-attributed disposable test
  and release outputs. Transactions `c1be1d2b9350e03b214525152c52df03` and
  `8043a71d399666cbe1439f645d9cdcb4` both applied without errors or residuals.
  The staged candidate, source checkout, historical caches, installed binary
  and verification evidence were preserved.
