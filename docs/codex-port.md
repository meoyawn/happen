# Codex port: remaining work

Reference: [OpenAI Codex](https://github.com/openai/codex), revision
`5112ce6edeb95f2296a5ffec47dbab4764e65853`. Upstream paths below are relative
to `codex-rs/`; individual source annotations retain their original revisions.

These are modified Dart implementations, not unmodified Rust sources. Codex is
Copyright 2025 OpenAI, licensed under Apache-2.0; see
[CODEX-LICENSE](../packages/openai/tools/CODEX-LICENSE) and
[CODEX-NOTICE](../packages/openai/tools/CODEX-NOTICE).

Only unfinished work is tracked here. **Final-source verification is pending.**
Desktop work and Flutter tests remain paused.

## Remaining gaps — handoff priority

### 1. Verify the final source

- The latest usage sibling run was **40 passed / 5 failed**
  (`happen-token-usage-runnable-first.txt`). Five older receipt assertions were
  corrected to require exact IDs and cumulative totals, but have not been rerun.
- The latest usage analysis reported **3 errors / 2 warnings** from the ternary
  expression in `TaskStore._restoreObservedUsage()`
  (`happen-token-usage-analysis.txt`). Its syntax repair has no analyzer rerun.
  Confirm receipt restoration and canonical transaction budgets on the corrected
  source; do not add a separate usage-receipt write.
- Rerun isolated analysis and usage/goal/storage siblings first, then the complete
  non-Flutter backend suite and **all 46** strict functional context cases:

```sh
dart --disable-dart-dev tool/test_isolated.dart analyze
dart --disable-dart-dev tool/test_isolated.dart test \
  packages/server/test/incomplete_response_test.dart \
  packages/server/test/goals_test.dart \
  packages/storage/test/architecture/commits_test.dart \
  packages/storage/test/architecture/replay_test.dart --concurrency 1 -r expanded
dart --disable-dart-dev tool/test_isolated.dart test --exclude-tags e2e \
  test packages/storage/test packages/server/test packages/agent/test \
  --concurrency 1 -r expanded
dart --disable-dart-dev tool/test_isolated.dart run tool/test_e2e.dart
git diff --check
```

Hot-reload an owned offscreen backend through DTD and probe the integrated
continuation/policy, native-item, storage/replay and usage behavior. Earlier
stopped probes and focused passes do not verify the final source. Preserve every
context vector and request-equality assertion, with no performance/timing verdict.
Keep source/package/home/config/build artifacts private to each check; do not
interrupt the human's desktop.

The referenced logs are local, not a portable final verification bundle:
`/private/var/folders/md/d3bz5pzj3l7_8_r0ykfjrg_h0000gn/T/opencode`.

### 2. Establish whole-workflow physical commit parity

No executable whole-workflow comparison against the **actual installed Codex**
was implemented or run. Implement comparable end-to-end workflows and record
physical persistence boundaries, including initialization, canonical/projection
batches, metadata and usage.

The native commit-hook assertions in
`packages/storage/test/architecture/commits_test.dart` and local physical WAL
budgets do not establish session-wide parity. Do not substitute SQL statement
counts, inferred Codex budgets or a Happen-only fixture for that comparison.

### 3. Finish the upstream applicability and coverage inventory

- **Provider/client/compaction/token records:** classify remaining applicable
  cases in `core/tests/suite/client.rs`, `core/tests/suite/compact.rs`,
  `core/tests/suite/token_usage_rollout.rs` and `core/src/state/session.rs`.
  Focused family coverage is not blanket agent-loop or usage-replay coverage.
- **Storage/import/replay:** complete the per-case ledger for partial/truncated
  JSONL, corrupt/compressed imports, split storage homes, relocation/migration
  and projection lifecycle. Distinguish existing ports from remaining cases and
  explicitly classify failure modes eliminated by SQLite atomic rows.
- **Native items:** finish the broader live-item inventory and integrated
  lifecycle/replay verification without reopening retired generic item paths.
- **MCP:** finish applicability classification for any remaining ordinary
  transport/OAuth/stdio/config cases. Mark each case as ported, adapted or
  excluded with its reason; do not infer universal parity from focused families.

For future in-scope repairs, port the applicable matrix before changing behavior,
retain qualified baseline failures and do not weaken inconvenient cases.

### 4. Close the remaining MCP proof boundaries

- **Platforms:** local macOS fixtures do not establish Linux or Windows process,
  descriptor, console/job-object behavior, or non-UTF-8 OS-string handling.
  Finish applicability classification and executable proof before claiming
  cross-platform parity. Absent remote-executor features are not local-test gaps
  to simulate.
- **Events interoperability:** public deployment interoperability and coverage of
  the complete experimental Events draft remain unproven by local lifecycle
  fixtures. Use `experimental-ext-triggers-events/docs/design-sketch-proposal.md`
  to classify the remaining boundaries.

### 5. Keep deferred presentation work separate

Desktop `/goal` controls, bounded goal-file loading, MCP input presentation and
the queued T3Code workspace presentation remain deferred. Backend caller-input
RPC proof is not desktop elicitation UX acceptance; do not fabricate answers,
device proofs or automatic URL handling.

When explicitly resumed, triage the remaining desktop fixtures against native
thread/items. Current-source Flutter verification is pending; neither the full
Flutter suite nor Moon `check` can be called green. Do not restore obsolete
production APIs to satisfy fixtures.

## Scope and constraints

- Preserve Happen's config schema, provider/API/lifecycle contracts and
  provider-generated IDs. Keep canonical RolloutLines and native projections
  transactional, one SQLite file/writer isolate per saved session, concurrent
  read-only readers, structural forks, and Codex's 256-step / 1 MiB
  threshold-crossing batches. Add no storage writer locks, shared-host coordinator
  or check mutexes.
- Codex alone is the MCP reference; ordinary OAuth is in scope. Config, not an
  individual request, owns shared stdio processes across aliases/projects/consumers.
  Preserve per-server-name/full-URL credential authority.
- Preserve explicit selected-cwd project scoping. Do not invent Codex trust-map
  or managed-policy YAML, or a network sandbox: network metadata reports
  `enabled: false`, not enforcement.
- Plugins, ChatGPT connectors, enterprise-managed authorization and remote
  execution are excluded. Do not invent sampling/roots, dynamic header helpers,
  keyring/backend selectors, hosted CIMD identities or external callback settings
  absent from Happen's schema just to reproduce Codex-only surfaces.
- Subagent execution, MultiAgentV2 mail/follow-up and live descendant-to-root
  accounting integration are excluded. Do not substitute an ordinary fork for
  their intentional skip or infer integration from counters alone.
- Cases requiring Dart HTTP-stack changes remain excluded. Preserve the user's
  independent native-HTTP migration; do not restore `third_party/http`, introduce
  a parallel codec or retain retired implementations.
