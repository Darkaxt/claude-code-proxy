# Windows scheduled updater

`update-proxy.ps1` and `start-updater-hidden.vbs` mirror the installed maintenance
scripts. The launcher remains hidden and propagates the worker's exit code.

The official-release updater must not overwrite our patched fork. Both Check
and Apply inspect the full executable version and build provenance before
staging or applying a stock archive. A custom suffix, fork metadata, missing or
malformed metadata, or a mismatched executable digest stops stock updating.
The log records `fork-integration-required`; an already pending archive remains
intact. Check still queries upstream and records its latest version.

For the fork, the next step is to review/integrate upstream changes in the fork,
run affected verification, build a patched candidate, and coordinate deployment.
This script intentionally does not merge patches or build arbitrary releases.
Only plain numeric official builds with matching official provenance and digest
retain the existing stock update path.

Verification:

```powershell
powershell.exe -NoProfile -NonInteractive -File .\test-update-protection.ps1
```

Installation: copy the verified `update-proxy.ps1` into the existing installation's
`maintenance` directory while holding `Local\ClaudeCodeProxyUpdater-mutex`.
No task, launcher, proxy binary or settings need changing. To stop scheduled
maintenance, disable the existing `Claude Code Proxy Weekly Update Check` and
`Claude Code Proxy Pending Update Apply` tasks; do not remove the guard to resume
stock installation over a fork. Version control retains the script history.
