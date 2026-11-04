# Codex storage and server port

The reference is OpenAI Codex, <https://github.com/openai/codex>. Initial
storage/goal ports used `f05aa41da6d063cd820dbad207d1cfabae594ff2`; subsequent
comparisons use `5112ce6edeb95f2296a5ffec47dbab4764e65853`. Short revision
annotations in individual files record their original source, not a claim that
every upstream test or feature has been ported.

These are modified Dart implementations, not unmodified Rust sources. Codex is
Copyright 2025 OpenAI, licensed under Apache-2.0; the complete license is retained
at [CODEX-LICENSE](../packages/openai/tools/CODEX-LICENSE). The upstream notice is
retained at [CODEX-NOTICE](../packages/openai/tools/CODEX-NOTICE).

## Architecture and intentional adaptations

- Each saved session has one `history.sqlite`, owned by one writer isolate.
  Concurrent readers open read-only WAL snapshots.
- Canonical records use Codex RolloutLine envelopes, ordinals, and byte positions.
  Native turns/items are rebuildable projections. Canonical writes and their
  projections share a transaction; a projection savepoint may fail without
  losing the canonical batch.
- Happen keeps provider-neutral model reconstruction data beside canonical rows.
  Portable exports carry optional Happen metadata; ordinary Codex response items
  can be reconstructed without that extension.
- Saved forks reference immutable ancestor prefixes using `history_base`.
  Archive changes collection metadata in place, preserving referenced ancestors.
  Portable export flattens lineage; it does not rewrite the ancestor.
- `/side` uses the same lineage machinery with a private in-memory SQLite child.
  It stores only its bookmark and suffix, and never copies the parent transcript
  or creates a saved side database. Inherited turns are model reference context;
  they are hidden from the side's public transcript.
- Goal state and continuation accounting belong to the host, surviving inference
  turns. Loaded threads retain their writer across idle operations.
- Terminal incomplete responses retain their provider reason and reported
  spending. The usage receipt and failed turn share one transaction; spending
  does not replace the last successful sampling/compaction baseline. Explicit
  `interrupted` responses continue sampling within the existing turn.
- **IDs remain provider-generated.** OpenAI supplies UUIDv7; OpenCode supplies
  descending `ses_…` IDs. The resolved provider governs start, fork, and import.
- No old Happen database migration or retired OpenCode projection compatibility
  is provided.

## Contract owners and source provenance

Paths below are relative to `codex-rs/` in the reference checkout. Tests are
adaptations at Happen's actual storage/transport boundaries; they are not an
assertion of complete upstream-suite coverage.

| Contract | Codex source/test family | Happen primary proof |
| --- | --- | --- |
| Recorder retention, canonical durability, projection recovery, timestamps, paging, summaries, realtime rows | `rollout/src/{recorder_tests,policy}.rs`; `thread-store/src/local/thread_history_materialization_tests.rs`; `thread_history/read_tests.rs` | `packages/storage/test/architecture/native_test.dart` |
| Native item payload conversion and persisted command/MCP output caps | `protocol/src/items.rs`; `app-server-protocol/src/protocol/v2/item.rs`; `rollout/src/policy.rs` | `packages/storage/test/architecture/native_test.dart` |
| Hidden subagent prefixes advance checkpoints without exposing inherited turns or realtime items | `thread_history_materialization_tests.rs::subagent_prefix_advances_projection_without_materializing_history` | `packages/storage/test/architecture/native_test.dart` |
| Structural/nested forks, named boundaries, active-turn interruption, archive, portable import/export | `thread-store/src/local/{paginated_fork,rollout_lineage,thread_history_materialization_tests}.rs` | `packages/storage/test/architecture/lifecycle_test.dart` |
| Exact provider context, inbox settlement, read-only snapshots | Happen integration around Codex canonical records | `packages/storage/test/architecture/integration_test.dart` |
| Goal identity, partial mutation, budgets, accounting modes, stale writes, fork deferrals | `state/src/runtime/goals.rs`; `app-server/src/request_processors/thread_fork_goal.rs` | `packages/storage/test/architecture/goals_test.dart` |
| Turn baselines, empty continuations, execution failures, concurrent descendant counters | `ext/goal/tests/accounting.rs` | `packages/agent/test/goals/accounting_test.dart` |
| Installed goal tools, serialized accounting, user evidence, continuation admission | `ext/goal/tests/{goal_extension_backend,steering}.rs` | `test/goal_tools_test.dart` |
| Goal API/notification order, cold restoration, compaction races, transport usage limits, writer retention | `app-server` goal processors; `thread_goal_empty_responses.rs`; `core` user-goal compaction tests | `packages/server/test/goals_test.dart` |
| All six SSE/WebSocket incomplete-response usage variants; content-filter diagnostics; terminal compaction accounting; no duplicate context estimate; same-turn interrupted continuation; goal spending and budget exhaustion | `core/tests/suite/client.rs::{incomplete_response_is_terminal,incomplete_response_emits_content_filter_error_message,incomplete_response_without_output_does_not_compact_the_next_turn}`; `compact.rs::incomplete_response_during_compaction_is_terminal_and_counted`; `session/tests.rs::record_token_usage_info_notifies_extension_contributors`; `codex-api/src/sse/responses.rs` | `packages/server/test/incomplete_response_test.dart` |
| Immediate local unsubscribe/unload and active-turn archive/interrupt drain goal accounting without cyclic waits | Happen lifecycle integration around the host-owned goal runtime | `packages/server/test/goals_test.dart` |
| Idle retention/resubscription, all five active-turn delay/ephemeral variants, cached systemError, all three repeated-unsubscribe variants | `app-server/tests/suite/v2/thread_unsubscribe.rs` | `packages/server/test/thread_unsubscribe_test.dart` |
| MCP Events draft push/poll/webhook occurrences cold-load their thread, including without a desktop; invalid signatures, control and duplicate deliveries do not run turns | Happen host integration with `experimental-ext-triggers-events/docs/design-sketch-proposal.md`; Codex's `mcp_event_stream.rs` only proves forwarding | `packages/server/test/thread_unsubscribe_test.dart` |
| Side first-message guard, boundary/policy, reuse, restrictions, cancellation and disposal | `tui/src/app/side.rs`; `tui/src/chatwidget/tests/side.rs` | `packages/server/test/side_chats_test.dart` |
| WebSocket initialization/authentication/Origin/health/shutdown | `app-server` transport and connection tests | `packages/server/test/websocket_test.dart` |
| Live/reconnected item reconciliation, turn retry, multiplexing and interruption | `app-server` v2 thread/turn contracts | `test/server_test.dart` |

## Commit limits

`packages/storage/test/architecture/commits_test.dart` counts SQLite's native
commit hook, including implicit writes. SQL statement counts are not commit
counts. The trace equivalent is `sqlite.commit`.

Verified budgets include:

- One canonical live batch plus projection: one commit.
- Terminal reported usage plus the failed turn: one commit. No extra receipt
  transaction or successful-context baseline update.
- Read/no-op/stale goal operations: zero; a changed goal: one.
- Cold tool settlement plus reset notice: one; warm ownership/no-op: zero.
  Initial runtime binding joins the next canonical write instead of committing
  runtime metadata by itself.
- Catch-up/import: Codex's 256-step / 1 MiB boundaries, including the record that
  crosses a byte threshold. A 601-record import uses five total commits: WAL
  initialization, schema initialization, and three data batches.
- Saved fork: three child commits, including initialization, independent of KV
  size; zero parent commits. Side storage is in memory and creates no side file.

These bounded tests do not establish a universal whole-session commit comparison
against every Codex workflow. That comparison remains a completion requirement;
passing unit tests must not be described as proving it.

## Verification snapshot — 2026-11-05

- The non-Flutter backend command (`dart test --exclude-tags e2e test
  packages/storage/test packages/server/test packages/agent/test`) passed 597
  tests, with the unsupported MultiAgentV2 unsubscribe case explicitly skipped.
- `dart analyze` completed without errors or warnings; informational lints remain.
- The full outbound-request matrix at
  `.local/context-contract/1793833077287019/report.json` passed 45 of 46 cases.
  All request-equality checks passed, including both cold-resume and goal modes.
  The remaining failure was `dart-evaluation-discovery`, mixed tool mode:
  median measured agent loop 14.586 ms versus Codex's 14.356 ms. Its strict
  timing assertion caused that historical failure. The current functional
  contract removes performance gates, stopwatches, and benchmark sampling;
  validation of that revision is recorded separately, not retroactively applied
  to this earlier run.
- The deterministic functional matrix at
  `.local/context-contract/1793834085284742/report.json` passed all 46 cases,
  with both execution orders and both tool modes retained. No speed or elapsed
  duration contributes to its verdict.
- The desktop question/reconnect protocol regression passed all seven offscreen
  tests in `packages/desktop/test/session_question_test.dart`.
- Hot reload was attempted, but no debug app or DTD was available. No desktop
  window was launched to work around that absence.

### Agent-loop batch

The new incomplete-response ports were run before their logic changed: all ten
initial cases failed on missing usage receipts or discarded provider reasons.
The goal-contributor adaptation then exposed a separate loss of reported totals
(`50` instead of upstream's `53`); both budget variants failed before that fix.
Both transport variants of explicit interrupted continuation also failed before
the matching nonterminal response mapping was ported. The native commit-budget
regression failed before the receipt was added to the terminal transaction.

The complete focused run of the new ports, commit budgets, goal lifecycle,
provider and retry siblings passed 120 tests. The two goal cases also verify
that spending, prior context usage and goal state survive a server restart.
Happen has no WebSocket prewarm, generic extension/plugin registry, or per-turn
model-switch fallback: those upstream harness mechanisms are not simulated.
The tests exercise the real goal contributor and repeat failed compaction with
the selected provider instead. This is bounded agent-loop proof, not a claim of
complete upstream client, compaction, token-record replay or backend coverage.

## Remaining verification and implementation work

- Run and repair the complete backend checks and the outbound-request E2E matrix
  after native-protocol migration. Keep all matrix cases; do not weaken request
  equality or remove inconvenient failures.
- Finish a case-by-case upstream coverage inventory. JSONL partial records,
  compression, split storage homes, rollout migration and
  projection cancellation are not all covered by the current SQLite tests.
  SQLite atomic rows remove some JSONL failure modes, but import and lineage
  behavior still need independent evidence.
- Native item replay supports core and extension variants. Live built-in calls
  still need the complete typed Codex command/file/image/sleep presentation,
  instead of using dynamic-tool items for every built-in. Terminal/shell work is
  deferred; the current scope is agent-loop behavior.
- Descendant counters are ported, but Happen does not yet expose Codex subagent
  execution. There is no live descendant-to-root accounting integration claim.
  `v2_child_idle_eviction_preserves_mail_and_followup_context` is explicitly
  skipped in the unsubscribe port for this reason, not replaced by a plain fork.
  Subagent execution, mail/follow-up and live descendant accounting are outside
  the current scope.
- MCP subscriptions/cursors survive thread unloading and desktop disconnect,
  but their restoration after a server process restart is not implemented.
  Accepted-occurrence receipts share the durable inbox transaction. Public deployment interoperability and the
  complete experimental Events draft are not claimed by local lifecycle fixtures.
- Complete desktop `/goal` controls and bounded goal-file loading, then the
  queued T3Code workspace presentation. Backend completion takes priority.
- Hot reload/live probing requires an available debug app and DTD. Offscreen
  tests must not interrupt the human's desktop.
