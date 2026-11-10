# Preserve patched proxy builds during scheduled updates

Authorization: already_authorized by the user's 2026-10-12 go-ahead.

R1: Never install a stock upstream archive over a custom, forked or unverifiable
installed build, including the existing pending v0.1.45 archive. Guard before
download/staging in Check and before any pending-state mutation or process
inspection/stop in Apply. Preserve the pending archive for manual integration.

R2: Continue checking upstream and report available versions with the full
installed version and explicit manual-fork-integration status. Permit the
existing stock update path only for a plain numeric version whose provenance
identifies the official repository/build kind and matches its executable hash.

R3: Preserve existing hidden tasks, schedule, OAuth, proxy settings, binary and
active process. Install only the corrected updater script. No proxy restart.

R4: Verify the real policy with regression tests (custom suffix, both fork
metadata schemas, absent/invalid provenance, wrong hash, legitimate stock),
then invoke the actual hidden Apply task and inspect its result/log and live
process identity. Commit the script, tests and specification.

## Stages

1. COMPLETE: R1-R2. The regression failed against the original updater, then
   passed under Windows PowerShell 5.1 after adding strict full-version,
   repository/build-kind and executable-hash checks. Both Check and Apply
   return before download, pending mutation or process control for protected
   builds. All nine policy cases passed; no automatic patch merging is added.
2. COMPLETE: R3-R4. Installed updater matches the verified source digest.
   Direct Check queried upstream v0.1.45 and reported fork integration without
   staging a new stock release. Direct Apply and the actual hidden scheduled
   Apply task both returned successfully with `fork-integration-required`.
   The scheduled task returned 0, retained its hidden wscript action, PT5M
   diagnostic execution limit and IgnoreNew collision policy. Proxy PID 65424,
   executable/config hashes and pending manifest hash remained unchanged;
   health stayed successful. No binary restart or settings change occurred.

## Verification evidence

- Windows PowerShell 5.1 policy matrix passed, including custom suffix, both
  metadata schemas, absent/empty/contradictory provenance, wrong digest and
  allowed official build. Native full-version extraction also passed.
- Initial actual Apply exposed early native-pipeline termination when using
  `Select-Object -First 1`; consuming native output to completion before reading
  LASTEXITCODE resolved it. Both actual execution paths subsequently passed.
- Scheduled Apply verification: 2026-10-12 15:14:39 UTC; LastTaskResult 0.
- Script SHA-256:
  `D75104BC4D2789B88A54EE9BA914CFD5BFCB125197B7FB86CF7285B5368AE156`.
- Preserved installed binary SHA-256:
  `A81FA5D3B4E8B3E1D997B2FA6E263A1107ABADBABFF04ACCE150318E4A2C7AB5`.
- Preserved pending manifest SHA-256:
  `5349833C889C9AF5E283BA158E7246B31676E2827D99CFC82AB491781D342315`.
- No expendable temporary outputs were created; source, tests, documentation
  and the installed updater are intentional persistent deliverables.

Blockers: none. Tracked deferrals: none.
