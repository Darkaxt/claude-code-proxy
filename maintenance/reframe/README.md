# ClaudeGPT desktop session manager

The desktop component is the history-preserving [Darkaxt/reframe](https://github.com/Darkaxt/reframe) fork, branch `codex/claudegpt`, based on Reframe 0.10.0. Its pinned source is the `apps/reframe` submodule (`git submodule update --init apps/reframe`). It uses this project's managed patched Claude CLI and existing proxy. Electron source/build/release stays independently versioned; Rust source does not embed or build the GUI. `component.json` distinguishes the source pin from final release/activation status. See the fork's `docs/claudegpt-spec.md` for authoritative requirements and `docs/CLAUDEGPT.md` for configuration, build, archive/recovery and release procedures.

ChatGPT uses the existing proxy/auth/model/effort. Anthropic uses Claude subscription authentication with session-only routing overrides. Both use the managed CLI executable, original history, native project instructions and permission controls. No automatic provider switching on failures or refusals. The GUI provider selection is an explicit owner action, independent of proxy maintenance.

Archive/delete uses the installed thread-cleanup helper and verified transactional-cleanup exact-file runtime through the packaged Python adapter. Machine paths/hashes and private activation receipts belong outside Git. No archive, transcript, credential, user profile or private verification packet belongs in this repository.

Keep the prior installed manager and launcher/state recovery at activation. Do not restart/rebuild the unchanged proxy or repatch the unchanged CLI for GUI-only changes. Preserve the existing daily automation; this integration creates no competing updater/task. Future monitored source upgrades must retain the fork and exact compatibility pins.
