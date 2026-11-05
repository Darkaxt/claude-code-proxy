# Managed Windows Claude client customization

Authorization: the owner selected tweakcc-fixed plus lobotomized-claude-code,
authorized upgrading the outdated CLI, installing the combination, and extending
the existing daily ClaudeGPT maintenance automation (2026-11-02).

## Requirements and acceptance

- C1: Install the newest mutually supported Windows x64 Claude Code release,
  published pinned tweakcc-fixed package, and pinned lobotomized prompt revision.
  Use ordinary files and native Windows; no WSL, symlinks, global npm install,
  new browser bridge, model router, refusal fallback or permission bypass.
- C2: Reuse community extraction, preflight and patch application. Review applied
  changes and verify the resulting executable, prompt replacements, startup,
  proxy request compatibility and unchanged model/provider/effort/credentials.
  Do not replay rejected inference. Preserve all conversations and project files.
- C3: Retain a versioned candidate with hashes, package lock, source revisions,
  validation logs and a known-good rollback with an actual restore procedure.
  Activation must refuse changed inputs and running Claude clients; do not stop
  clients or the proxy. Verify installed hashes and configuration independently.
- C4: Let the existing daily 09:00 Europe/Bucharest automation monitor the proxy,
  tweakcc-fixed and lobotomized-claude-code, plus the compatible official CLI.
  Review updates, stage and verify before safe activation, preserve local changes,
  avoid duplicate workers and remain quiet on unchanged state. Suppress only the
  CLI's competing background updater via documented DISABLE_AUTOUPDATER=1;
  preserve other settings. Failed checks leave the live installation intact.
- C5: Keep reusable maintenance in this repository and private state under
  D:/Tools/claudegpt-maintenance/client. Temporary npm/native I/O uses the exact
  D:/Temp/claudegpt-client-20261102 directory (small-file/native I/O exception),
  cleaned transactionally after its last consumer. Commit and push verified
  maintenance changes normally; do not modify unrelated dirty documents.
- C6: Preserve task-scoped durable user authorization in the managed action-safety
  prompt (owner correction, 2026-11-05). Already authorized commits, pushes,
  releases and closure writes must not demand new confirmation solely because
  they affect shared state or their implementation payload evolves. Re-inspect
  changes and ask only for genuinely new authority, a material scope change or
  a missing user decision. Preserve actual host/tool approval controls, provider
  enforcement, credential protection and truthful reporting. Apply the reviewed
  local adaptation before community preflight/application; refuse unreviewed
  community drift or local edits instead of silently replacing them. Verify the
  adapted native payload and benign decision scenarios through the actual CLI.
  When --dangerously-skip-permissions is active, it governs routine CLI approval
  behavior: do not add conversational permission questions as a replacement for
  skipped tool dialogs. This preserves task scope and actual host/tool/provider
  enforcement. Exercise the behavior probe with that native flag enabled.

## Stage scope and reconciliation

The execution ledger is the dated private client run `STATUS.md` under
`D:/Tools/claudegpt-maintenance/client`. Keep exactly one current status for each
stage there; receipts and `active.json` identify the actual installed tuple.

1. Candidate preparation and qualification (C1, C2, candidate part of C3): verify
   pinned signed vendor input, community profile/application, exact native payload
   readback and cleared bytecode, startup and a real no-tool proxy reply. Retain
   the qualification, original failures and compatibility limits in the release.
2. Final local delivery and recurring maintenance (C3, C4, C5): verify owned
   activation and rollback, scheduler update/readback, installed real request,
   source synchronization, protected state and transactional scratch cleanup.

The initial delivery independently recovered a community postwrite EBUSY cleanup
error: candidate/temp hashes matched, patcher processes exited, exact payload,
startup and real-request checks passed, and the spent temporary file was removed
through transactional-cleanup. Do not report the original community command as
successful, treat missing/nonunique Windows catalogue sites as applied, or turn
this one diagnosed result into a universal exception for future failures.
The prompt-pack README's 2.1.280 badge is stale: revision
75289f5735e589dbc80905b83785250131efe9d8 explicitly updates to 2.1.316,
matching tweakcc-fixed 2.9.22's supportedClaudeCode declaration and npm's current
official CLI release. This is the initial candidate tuple, subject to validation.
