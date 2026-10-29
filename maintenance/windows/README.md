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

## Verified fork activation

`deploy-fork.ps1` is the separate, reusable local fork deployment transaction.
It requires PowerShell 7.2 or newer and reuses the installed Windows PowerShell
supervisor. Its default is read-only validation; explicit `-Apply` performs the
owned restart and installation. Neither mode changes schedules or the stock
updater's guard.

```powershell
.\deploy-fork.ps1 -ManifestPath D:\Tools\proxy-release\deployment.json
.\deploy-fork.ps1 -ManifestPath D:\Tools\proxy-release\deployment.json -Apply
```

The private JSON manifest has schema `claudegpt.fork_deployment.v1`. Supply:

- `candidateBinary`, `candidateSha256`, `version`, `sourceCommit` and
  `integratedUpstreamCommit`: exact already-verified runtime identity.
- `verificationPath` and `verificationSha256`: the retained verification JSON.
  It must show passing tests, optimized build, isolated startup and child exit,
  and bind the same binary digest and upstream commit.
- `sourceRepositoryPath`: the maintained Git checkout used to verify that the
  exact runtime commit's tree matches the verification evidence. Wrapper-only
  source changes do not require recompiling an unchanged runtime.
- `installDirectory`, `configDirectory`, `logDirectory`, `instanceName` and
  `baseUri`: the existing supervisor installation and loopback endpoint.
- `expectedInstalledHash`, `expectedInstalledBuildInfoHash`: fresh known-good
  baseline hashes; unexpected changes refuse activation.
- `protectedFiles`: objects with absolute `path` and `sha256`. For production,
  include proxy configuration, dynamic model catalog and client settings.
- `recoverySkillPath` and `persistentScratch`: installed recovery instructions
  and a persistent tool-owned directory on D: or E:. These are passed only to
  the controlled launcher environment, not global user settings.
- `requiredModelIds`: catalog entries that must be present after activation.
- `rollbackDirectory`: a new exact recovery directory for this activation.
  The transaction stores one matching executable/provenance pair and restore
  instructions. Retain this pair while it remains the active rollback.
- `receiptPath`: private JSON result outside Git.
- `consumerReviewPath` and `consumerReviewSha256`: a scoped owner review with
  `reviewed: true`, `unresolvedConsumers: []` and evidence about background
  agents, automated continuations and scheduled request producers. This review
  supplements the fresh monitor and Claude-process checks; an empty monitor is
  not an admission reservation. Refuse activation if consumer safety is unclear.

The default consumer gate refuses any running Claude client. An explicit owner
pause can instead be recorded in that hash-bound review with
`userConfirmedPause: true`, `pauseScope: "listed-clients-and-continuations"`, a
nonempty `pauseAuthorizationSource`, and `pausedClients` entries containing
`pid`, UTC `started`, `executablePath` and `paused: true`. This requires the user
to have paused all listed threads and their request-producing continuations for
the restart. It is not an inferred pause from an empty monitor or low activity.
The exact complete current Claude process set must match those identities at
each deployment check. Any established loopback connections must resolve to
those clients, and active proxy requests still refuse activation. New/replaced
clients, unknown socket peers or an unresolved producer invalidate the review.
This contract neither stops client processes nor resumes their threads.

The transaction binds supervisor/child start identities and executable paths,
uses the existing updater mutex and supervisor stop event, observes exits, and
starts the same supervisor without a console. Startup observation uses native
file/process events and diagnostic HTTP boundaries, with no execution deadline.
The server's listener event is mirrored to the supervisor's existing content-free
stderr category log. Protected configuration files are never copied or edited.

If post-stop installation/startup/verification fails, the transaction stops its
owned replacement, restores both known-good files, restarts through the same
controlled supervisor and verifies the original version, hash and model catalog.
`rolled_back` is reported only after recovery verification; otherwise the receipt
says `recovery_incomplete`. Preserve the receipt and exact rollback paths.

For manual recovery, inspect the manifest and receipt, establish safe consumers,
stop and observe the recorded owned supervisor/child, restore the receipt's two
rollback files to the installation, and use the script's `Start-ForkSupervisor`
and `Wait-ForkReady` functions with that same manifest and original hash/version.
Put any recovery automation in a reviewed script file. Never overwrite changed
configuration to make a recovery check pass.

`test-deploy-fork.ps1` exercises an isolated installation on an OS-selected port,
using real verified binaries and the existing supervisor. It proves non-activating
validation, pre-stop refusals, controlled activation, and recovery after a real
post-start catalog check fails. It performs no inference. Supply an exact new
fixture directory and retain/clean its output through transactional-cleanup only
after all owned processes exit. The fixture uses the supervisor's existing
process-name scope option so it can coexist with production; production retains
the original global collision guard. The existing supervisor fixes state home
to LocalAppData, so its fixture may append metadata to the existing shared proxy
log; never delete that pre-existing log as fixture cleanup.

## Fork environment at sign-in

Deployment sets a process-local environment, which is lost when the original
Startup launcher runs after reboot. `start-fork-hidden.vbs` supplies that same
environment to the existing adjacent `supervise-proxy.ps1`. It requires two
explicit arguments: an existing D:/E: persistent scratch directory and an absolute
installed recovery-skill path. Missing inputs refuse launch. It uses hidden
Windows PowerShell, waits for actual supervisor exit and propagates its result.
It never changes global environment, provider settings, schedules or collision
controls. The extra waiting wscript process exits when its supervisor exits.

`install-fork-startup.ps1` updates only the existing installed `start-hidden.vbs`
and existing Startup shortcut, under the existing updater mutex. Default mode
validates without changes; `-Apply` installs; `-Restore` restores the exact saved
launcher/shortcut pair after verifying the installed receipt. No mode restarts
the live proxy. Use the usual safe-consumer deployment transaction separately
when the current processes need the corrected environment.

The private manifest schema is `claudegpt.fork_startup.v1`, with absolute paths
`launcherSource`, `installedLauncher`, `startupShortcut`, `persistentScratch`,
`recoverySkillPath`, `rollbackDirectory` (new) and `receiptPath`. Bind SHA256 values
`launcherSha256`, `expectedLauncherSha256`, `expectedShortcutSha256`, plus exact
old shortcut `expectedArguments`. The shortcut must already target system
wscript.exe with its installation directory as working directory. Retain the
manifest, receipt and rollback pair for restoration; restore refuses unrelated
changed files. Unchanged Rust verification remains applicable to this wrapper.

Run `test-fork-startup.ps1 -FixtureRoot <new-exact-task-directory>` for an isolated
real Windows launcher/installer/restore check, including clean-parent environment
propagation, invalid-input refusal, non-activating validation and exact restoration.
The fictional supervisor exits without serving or invoking a provider. Clean
the fixture transactionally after its owned process completion.
