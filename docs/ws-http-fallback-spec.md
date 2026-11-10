# WebSocket-to-HTTP Recovery Specification

Status: implementation authorized by the user on 2026-09-27.

## Problem

Codex WebSocket requests can exhaust bounded reconnect attempts before any
downstream content is emitted. Repeating the same WebSocket path leaves an
affected Claude session unable to make progress even while other sessions and
the proxy remain healthy.

## Requirements

- R1: WebSocket remains the configured and normal Codex transport.
- R2: After bounded WebSocket recovery is exhausted, a request that has emitted
  no downstream model content is attempted once through the existing HTTP
  transport before an error is returned.
- R3: Requests that have emitted downstream model content must not be replayed
  through HTTP, preventing duplicated visible output or tool calls.
- R4: The HTTP fallback must not recurse into another transport fallback or
  create an unbounded retry loop.
- R5: Existing successful WebSocket, continuation, compaction, and monitoring
  behavior must remain intact.

## Acceptance criteria

- AC1: A regression test fails on the pre-fix implementation when WebSocket
  recovery is exhausted before output and expects one HTTP attempt.
- AC2: The regression test passes after the minimal implementation.
- AC3: Existing focused Codex provider tests pass.
- AC4: The Windows release binary builds successfully from the integrated
  v0.1.42 plus PR 158 source.
- AC5: The deployed binary reports the intended custom version and starts with
  the existing configuration, without changing the configured transport.

## Staged execution

1. COMPLETE - Integrated the v0.1.42 baseline with PR 158 and the preserved
   compaction patch. The regression test failed before the fix and passed after
   it; all 421 Codex-provider tests pass after restricting fallback to
   connection and 5xx failures.
2. COMPLETE - Built and staged `0.1.42-pr158.compaction3`; the staged Windows
   binary reports the custom version and has SHA-256
   `5302CD4D26569FB030052D5691C5E6541E76C73A93FBF7709624353F5F3E2191`.
3. COMPLETE - Waited for zero active proxy requests, stopped the owning
   supervisor through its explicit event, replaced the binary, and relaunched
   the same hidden supervisor. The installed binary hash matches the staged
   artifact, `/monitor` responds on port 8317, and the unchanged configuration
   still selects WebSocket with continuation and server compaction enabled.

Blockers: none.

Tracked deferrals: none.
