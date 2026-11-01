# Upstream v0.1.48 integration

Recurring maintenance authority integrates upstream 49cf15220b2efa94b3d21c1a560d3762e961628d through normal merge history while preserving the fork's existing contracts.

Adopt upstream reasoning/subscription usage reporting, opt-in full Responses lane and continuation isolation checks, Terra compatibility assertions, and isolated routing/logout tests. Full lane stays disabled by default and does not alter provider, model, effort, service tier, credentials or access programs. Preserve the fork's policy classification/nonretryable flow, durable owner-scoped notices, compaction, content-free recorder and updater/deployer behavior.

Intentional integration differences:

- Retain WebSocket as implicit transport, with the fork's existing bounded recovery and no replay after downstream output. Keep explicit auto/HTTP selections and upstream precedence assertions.
- Retain the single `codex_models` catalog for listings, routing, request lanes and explicit cache discovery, including aliases, local overrides and last-good snapshots. The additional upstream implicit CLI-cache owner and its incompatible discovery tests are omitted; existing `runtime_codex_models` tests cover the fork contract. Add upstream's GPT-6.1 Terra to the bundled baseline: the live installation already discovers it through its explicit cache, but a clean installation must support it too.
- Retain strict successful acknowledged `ScheduleWakeup(noop:true)` completion. Ordinary tool-result tails still require meaningful output; upstream PR 122's broader acceptance and its incompatible tests are omitted. Existing no-op positive/negative transport matrix remains authoritative.
- Isolated provider tests wait for their actual child result; no newly introduced process-kill deadline or polling loop. Their temporary environment stays in the test-owned directory.

Verify the integrated runtime with library tests and affected usage, WebSocket/lane, CLI/server, dynamic catalog, policy/restart and cutover integrations, installed ledger fixtures, stock-updater guard, formatting, optimized two-job Windows build and isolated native startup/catalog/exit. Deployment follows the existing private manifest and safe-consumer contract; no open PR branches or stock binaries are imported.
