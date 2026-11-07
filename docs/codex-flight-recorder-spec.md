# Codex failure flight recorder

## Authoritative requirements

Add a rolling, metadata-only diagnostic recorder for Claude's Codex Responses
requests. Keep the last 128 events per upstream attempt; discard successful
attempts, and save one snapshot when an attempt fails, including failures after
HTTP 200 / after semantic output. This is diagnostics, not a recovery change:
do not change transport, retry, cancellation, compaction, or timeout behavior.

Record build version, UTC start, elapsed milliseconds, request/session correlation
fingerprints, model fingerprint, transport, input item count, continuation
fingerprint, compaction-boundary state, event type/category, numeric token usage,
semantic/terminal state, error origin/status/class, and WebSocket close code and
reason byte count when supplied. Never retain prompts, output/reasoning text,
tool arguments, headers, credentials, raw error messages or close reasons.
Unknown event names and error details must become fixed categories, not raw text.

Bound memory by a fixed schema and ring length, each file to 128 KiB, and owned
captures to 100 files / 10 MiB. Only regular, non-reparse files with the recorder's
UUID filename format in its dedicated state-directory subfolder may be pruned.
Diagnostic I/O failures must not replace the original request error. Filesystem
work must run off the async request executor. Preserve unrelated files.

Prepare a versioned Windows binary and build provenance for later deployment.
Do not replace the installed binary, restart the proxy, or change live settings.

## Stages and acceptance

1. Recorder and integration — COMPLETE
   - Bounded ring, fixed-schema privacy, success discard, error snapshot and
     count/byte retention verified with focused tests.
   - Streaming HTTP/WebSocket startup, upstream error, EOF, translator and empty
     completion failures connected to recording; buffered Responses and native
     server compaction failures connected as well.
   - Close-frame metadata survives without recording its free-form reason.
   - No new retry/deadline/fallback behavior.
2. Verify and stage — COMPLETE
   - Focused integration regression tests, formatting, release build and version
     check pass; requirements reconciled; verified changes committed.
   - Candidate binary and provenance staged separately; live process, binary and
     settings unchanged. Deployment explicitly remains pending user direction.

Stage 1 evidence: recorder unit tests pass; the Codex provider regression suite
passes; local HTTP event-error, mid-response WebSocket close, success-discard and
startup authentication / writer-failure integration checks pass. The existing
smoke suite's unchanged checks pass; an initial new assertion incorrectly assumed
the first HTTP event was the error rather than a control event. The corrected
error-event lookup passes. No production behavior was changed to satisfy that
assertion. No blockers or tracked deferrals remain in Stage 1.

Stage 2 evidence: final recorder unit and integration checks pass; format/diff
checks pass; Clippy reports only the eight pre-existing Windows warnings. The
optimized Windows build passes and its version is `0.1.42-pr158.stream1.catalog1.provenance1.noop1.recorder1`.
The byte-identical isolated health copy returned `{ "ok": true }` on ephemeral
port 58887, then exited. No real inference request was made. The candidate and
build-info JSON are staged in the versioned install `staging` directory and were
digest/size/source-commit checked. The verified implementation was committed.
Task-owned release intermediates and validation scratch were removed through a
reviewed cleanup ticket; the staged deliverable was preserved. The live listener
remains PID 65424 and installed binary / proxy config / Claude settings hashes
match their pre-task values. No blockers or tracked deferrals remain.

**Deployment is not part of this completed scope and has not occurred.** Await
the user's separate activation direction; no updater pending manifest was changed.

## Operational location

`state_dir()/diagnostics/codex-flight-recorder/ccp-flight-<UUID>.json`.
Windows default: `%LOCALAPPDATA%/claude-code-proxy/diagnostics/codex-flight-recorder`.
Snapshots are local diagnostic evidence, not automatically uploaded.

The Windows supervisor sets `XDG_STATE_HOME` to Local AppData; the recorder follows
the existing proxy state resolver. This does not change the resolver or launcher.

## Diagnostic contract and limitations

The recorder is enabled without a settings change. A request UUID is retained
only if it parses as a UUID; other correlation identifiers are SHA-256
fingerprints. Model names are an explicit fixed allowlist plus a fingerprint for
unrecognized names. Compaction-boundary state is null when the caller has not yet
provided it; token estimates and usage appear only when available. Error status
is the proxy's classified status; numeric upstream status is separately retained
on events that supply one. Error codes use an explicit fixed allowlist.

Each failed stream attempt saves at most once, including attempts subsequently
retried by existing recovery logic. The failure snapshot freezes the last 128
events; earlier events are counted as dropped. Captures are 128 KiB maximum,
retained oldest-first to 100 files and 10 MiB in the dedicated directory. Eight
blocking writes may be outstanding at once; overload drops additional snapshots
and emits `flight_recorder_queue_full` rather than delaying requests. Write errors
emit `flight_recorder_write_failed` without changing the API response.

Cancellation alone is not failure. Completed attempts are discarded. Process
termination before an error is observed cannot produce a snapshot. The recorder
does not know an upstream reason that OpenAI never sent; a bare disconnect can
still be distinguished from a close frame or an upstream error event. Close
frames supply numeric code and reason length, never the reason text. Captures do
not replace or expand the pre-existing opt-in full traffic capture feature.
