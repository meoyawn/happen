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
| All six SSE/WebSocket incomplete-response usage variants; terminal compaction accounting; no duplicate context estimate; same-turn interrupted continuation; goal spending and budget exhaustion | `core/tests/suite/client.rs::{incomplete_response_is_terminal,incomplete_response_without_output_does_not_compact_the_next_turn}`; `compact.rs::incomplete_response_during_compaction_is_terminal_and_counted`; `session/tests.rs::record_token_usage_info_notifies_extension_contributors`; `codex-api/src/sse/responses.rs` | `packages/server/test/incomplete_response_test.dart` |
| Content-filter classification, retained delivered output, bounded catalog/default guidance after each block (including exhaustion), sampling/compaction separation and durable host admission before retry | `core/tests/suite/scenarios_content_filter.rs`; `core/src/{responses_retry,context/content_filter_guidance}.rs`; `prompts/src/model_messages.rs` | `test/openai_retry_test.dart`; `test/context/content_filter_test.dart` adds concurrent SQLite reads before every retry and restart/replay proof |
| Agent-invoked command start/completion, logical process IDs, all three launch variants, cold replay, direct/nested background exits attributed to their original turn | `app-server/tests/suite/v2/turn_start.rs::command_execution_notifications_include_process_id`; `core/tests/suite/unified_exec.rs::unified_exec_full_lifecycle_with_background_end_event` | `packages/server/test/command_execution_test.dart` |
| Immediate local unsubscribe/unload and active-turn archive/interrupt drain goal accounting without cyclic waits | Happen lifecycle integration around the host-owned goal runtime | `packages/server/test/goals_test.dart` |
| Idle retention/resubscription, all five active-turn delay/ephemeral variants, cached systemError, all three repeated-unsubscribe variants | `app-server/tests/suite/v2/thread_unsubscribe.rs` | `packages/server/test/thread_unsubscribe_test.dart` |
| MCP Events draft push/poll/webhook occurrences cold-load their thread, including without a desktop; invalid signatures, control and duplicate deliveries do not run turns | Happen host integration with `experimental-ext-triggers-events/docs/design-sketch-proposal.md`; Codex's `mcp_event_stream.rs` only proves forwarding | `packages/server/test/thread_unsubscribe_test.dart` |
| Shared stdio startup/cancellation/retirement, global/local reuse, namespace isolation, project layering and scoped stdio/URL inventory | `codex-mcp/src/connection_pool_tests.rs`; `app-server/tests/suite/v2/mcp_server_status.rs::mcp_server_status_list_uses_thread_project_local_config`; `config/src/{merge,loader/mod}.rs`; `core/src/config/config_loader_tests.rs` | `test/mcp_pool_test.dart`, `test/config_reload_test.dart` |
| Ordinary MCP OAuth discovery GET-first, resource-header isolation, same-origin redirects, cycles, missing/mismatched issuers and the complete 8×2 untrusted-metadata login matrix | `rmcp-client/tests/mcp_2026_oauth_discovery.rs` (plugin redirect mode excluded); `src/{auth_status,oauth_http_client}.rs`, `src/oauth/issuer_binding.rs` | `test/mcp_oauth_discovery_test.dart`; WebSocket/CLI integration remains in `test/mcp_auth_test.dart` |
| Modern JSON/SSE metadata, evidence-only legacy downgrade, correlation, complete prevalidation/version vectors, handshake retry and legacy HTTP-session recovery | `rmcp-client/tests/{mcp_2026_discovery,mcp_2026_sse_discovery,streamable_http_recovery}.rs`; `src/{http_client_adapter,streamable_http_retry}.rs` | `test/mcp_transport_test.dart` |
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
- Foreground CLI completion admission and intervening streaming records: zero.
  The completion joins the next ordinary tool-result or cancellation commit,
  with its native item and projection in that same transaction.
- Catch-up/import: Codex's 256-step / 1 MiB boundaries, including the record that
  crosses a byte threshold. A 601-record import uses five total commits: WAL
  initialization, schema initialization, and three data batches.
- Saved fork: three child commits, including initialization, independent of KV
  size; zero parent commits. Side storage is in memory and creates no side file.

These bounded tests do not establish a universal whole-session commit comparison
against every Codex workflow. That comparison remains a completion requirement;
passing unit tests must not be described as proving it.

## Verification snapshot — 2026-11-05

- The latest non-Flutter backend command (`dart test --exclude-tags e2e test
  packages/storage/test packages/server/test packages/agent/test --concurrency 1`)
  passed **951 tests**, with two explicit skips: unsupported MultiAgentV2 and the
  user-excluded configured UTF-8 HTTP header case. Evidence:
  `happen-mcp-stdio-cleanup-backend.txt`. This includes the stdio cleanup batch
  and predates the Events restart matrix.
- Current workspace `dart analyze` completed without errors or warnings;
  151 informational diagnostics remain (`happen-mcp-stdio-cleanup-analysis-repaired.txt`).
  The four new shared-challenge-parser warnings have been removed.
- The full outbound-request matrix at
  `.local/context-contract/1793833077287019/report.json` passed 45 of 46 cases.
  All request-equality checks passed, including both cold-resume and goal modes.
  The remaining failure was `dart-evaluation-discovery`, mixed tool mode:
  median measured agent loop 14.586 ms versus Codex's 14.356 ms. Its strict
  timing assertion caused that historical failure. The current functional
  contract removes performance gates, stopwatches, and benchmark sampling;
  validation of that revision is recorded separately, not retroactively applied
  to this earlier run.
- The current deterministic functional matrix at
  `.local/context-contract/1793872907311203/report.json` passed all 46 cases
  after the stdio repairs (`happen-mcp-stdio-cleanup-e2e.txt`). Earlier
  deterministic runs were `.local/context-contract/1793844987790360/report.json`,
  `.local/context-contract/1793840281044263/report.json` and
  `.local/context-contract/1793834085284742/report.json`,
  with both execution orders and both tool modes retained. No speed or elapsed
  duration contributes to its verdict.
- The focused native-protocol widget run passed all nine offscreen tests in
  `packages/desktop/test/{session_question,thread_timeline}_test.dart`.
- The complete offscreen Flutter suite is **not green**: 98 tests passed and 68
  failures were reported, including compilation and teardown fallout. Existing
  fixtures still exercise retired session protocols: sidebar mocks reject
  `thread/list`, the sleep fixture casts Responses content arrays to strings,
  and tracked `test/.settings_visual_review_test.dart` references the removed
  `DesktopTask.events` getter. These representative failures do not classify all
  68 reports as independent regressions. No desktop fixtures were deleted,
  skipped, or rewritten, and no obsolete production API was restored.
- An isolated, offscreen Dart backend probe was connected directly through the
  VM service and hot-reloaded successfully. Its real local HTTP response was
  `{"text":"A permitted alternative.","requests":3,"guidanceCounts":[0,1,2],"coreEnvironment":true}`.
  The probe was explicitly stopped afterward. No Flutter window was launched or
  reloaded; desktop work and Flutter tests remain paused.
- The subsequent ordinary OAuth startup/runtime batch passes all **29** new
  cases after a **13-pass / 16-failure** settled baseline. Expanded MCP siblings
  pass **223 tests / 1 intentional skip**. The OAuth offscreen VM hot reload
  returned `{"startupRefreshes":1,"totalRefreshes":2,"toolCalls":0,"isError":true,"credentialsPreserved":true}`;
  its owned process was explicitly stopped. See [MCP inventory](mcp-port.md) for
  exact evidence logs and the remaining security/locking matrices. The full
  analysis/backend/E2E rerun for this batch is included in the snapshot above.
- The next callback/HTTP-security batch passes **115 OAuth-focused cases**,
  including 55 new native callback/HTTP ports. Its settled pre-repair baseline
  was **25 passed / 25 failed** among the first 50 ports. A further two-case
  baseline retained identifiable timeout diagnostics before that repair. The
  final offscreen hot reload returned
  `{"invalidCallbackRejected":true,"codeExchanges":1,"authenticated":true}`
  and the startup/non-replay probe still passed. See `happen-mcp-oauth-security-repaired.txt`
  and the [MCP inventory](mcp-port.md). The subsequent full backend run was
  **882 passed / 2 intentional skips / 1 failed**
  (`happen-oauth-security-backend.txt`): retained
  `session_list_test.dart::native thread listing discovers durable interrupted
  sessions without running their tools` returned an empty listing. No storage
  assertion was weakened or skipped. Its cause is not yet established; focused
  triage is recorded separately. The sequential E2E stage did not run after
  this failure. The 828-test green snapshot above predates this run.
- Applicable ordinary OAuth registration ports now pass **17** cases after a
  **13-pass / 4-failure** settled baseline. Real TLS-origin tests enforce exact
  provider exceptions; DCR selection, delegated endpoints, unchanged native
  redirects and Basic/Post credential-header isolation are covered. Combined
  OAuth and retained session-list siblings pass **134 tests**
  (`happen-mcp-oauth-registration-first.txt`). The empty-listing failure above
  did not reproduce there; no storage source or assertion was changed and its
  cause is not considered fixed. The current full sequence is backgrounded in
  `happen-oauth-registration-{analysis,backend,e2e}.txt`. See the [MCP inventory](mcp-port.md)
  for complete registration applicability and the remaining lock/race work.
  The offscreen registration hot-reload probe returned
  `{"registrations":2,"codeExchanges":1,"basicOverridesResourceAuth":true,"resourceKeyPreserved":true}`;
  startup/non-replay behavior still passed and the owned process was stopped.
  The completed full rerun then passed **900 backend tests / 2 intentional
  skips**, analysis with **0 errors/warnings**, and **46/46** E2E cases. The
  earlier listing failure did not recur in that full run either; no speculative
  storage repair was made and its historical failure remains recorded above.
- The following credential-transaction batch passed its original **40 cases**
  after a **28-pass / 12-failure** baseline, including real distinct-owner,
  isolate/process, failed-save, replacement, cancellation and lock timeout/death
  boundaries. A 41st regression reproduced a rejected grant being readopted
  after JSON key reordering; semantic generation equality now guards that path
  and the **41-case rerun passed** in `happen-mcp-oauth-credentials-repaired.txt`.
  Expanded MCP siblings passed **335 / 1 scope skip**, then strict analysis
  caught two indexing type errors and one generic inference warning in that
  comparer. The type is now explicit; repaired workspace analysis has **0
  errors/warnings** (143 infos), and all **3** formatting/non-replay cases pass
  in `happen-mcp-oauth-credentials-non-replay-final.txt`. The stopped sequence
  did not run backend/E2E; the final rerun is separately backgrounded in
  `happen-mcp-oauth-credentials-final-siblings.txt` and
  `happen-oauth-credentials-{backend,e2e}.txt`. That final-source sequence
  completed with **336 siblings / 1 scope skip**, **941 backend tests / 2
  intentional skips**, and **46/46** deterministic context cases.
  The offscreen hot-reloaded probe returned
  `{"refreshCalls":1,"bothUsePersistedToken":true,"refreshTokenPreserved":true,"scopePreserved":true}`;
  both owned probe processes were stopped. See [MCP inventory](mcp-port.md) for
  complete applicability, exact logs and the pending siblings/full rerun. These
  results do not establish Events restart restoration or whole-workflow commit
  parity.
- All applicable process-group, descriptor and queued-stderr cleanup cases from
  Codex's three stdio cleanup files are ported. The qualified baseline was
  **2 passed / 4 failed**; all six pass after repair. Four further native NUL
  rejection cases each failed before repair, and the final **10-case** rerun
  passes (`happen-mcp-stdio-cleanup-repaired.txt`). Earlier pooling/environment/
  reload siblings pass **45**, repaired analysis has **0 errors/warnings**, and
  the final-source hot-reload probe confirmed shared ownership, isolated groups,
  descendant/in-flight cleanup, closed stderr FDs and retained queued diagnostics
  while an escaped child stayed alive. The owned probe was stopped. The full
  siblings/backend/E2E sequence is backgrounded in
  `happen-mcp-stdio-cleanup-{final-siblings,backend,e2e}.txt`; it is not yet the
  full-suite snapshot above. See the [MCP inventory](mcp-port.md) for exact
  baselines, fixture qualification, platform limits and the still-open contracts.
  That final stdio sequence completed with **346 MCP siblings / 1 scope skip**,
  **951 backend tests / 2 intentional skips**, and **46/46** context cases.
- At the user's request the shared `happen-dart-checks` mutex was removed.
  Moon analysis/unit/E2E commands now use `tool/test_isolated.dart`: the current
  dirty source is snapshotted, mutable package/plugin/hook/test artifacts are
  private to the run, and vendored source/SDK trees remain shared read inputs.
  The raw VM starts the isolation wrapper before `dart run` can build hooks in
  the human's checkout. E2E reports still go to the original `.local` directory;
  failing workspaces are retained. Concurrent isolated stdio/config tests pass
  **15** cases. The first isolated analyzer exposed missing standalone lint
  plugin dependencies; the wrapper now resolves them separately, with a repaired
  concurrent verification recorded in `happen-check-isolation-analysis-repaired.txt`.

### Shared MCP/runtime repair batch

- The CLI cancellation contract now reads the native command's logical
  `processId`, not an obsolete dynamic `exec_command` item. Both providers pass
  the original cancellation/process-lifetime matrix.
- Both global-first and local-first executable reloads reproduced overlapping
  process generations before the fix. The independent replacement child records
  live predecessors; the repaired manager drains all equivalent bindings across
  scopes before launching. Ordinary last-owner replacement also drains before
  publishing its successor. Reload/pooling/cancellation siblings passed 23 tests.
- A valid but unencodable assistant-context record reproduced silent acceptance
  after native staging gained its no-write return. The invariant now runs before
  that return, rejecting the record without advancing memory or committing.
- The analyzer safety contract passes alone and within the full serial backend
  run. Its original two-minute timeout occurred with a concurrent workspace
  analyzer. No timeout was increased, and the pooling environment-isolation
  timeout did not recur in the successful focused/full runs.
- Moon `check` still depends on `test-unit`, `test-e2e`, and `analyze`. Those tasks
  no longer share a mutex: per the user's correction, they each run in a private
  source/package/artifact snapshot through `tool/test_isolated.dart`. Concurrent
  isolated analysis completes with **0 errors/warnings**, while independent
  stdio/config checks pass **15 tests**. The standalone analyzer plugin resolves
  its own dependencies inside that snapshot, not the human's checkout. The Moon
  wrapper itself was not run; its full check cannot be
  called green while the complete Flutter suite has the failures above.

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

## Content-filter recovery completion batch

The nine new cases all failed before the implementation change:
`happen-content-filter-baseline.txt`. A blocked response was classified as a
terminal `incomplete_response`, with no recovery request or recorded guidance.
They now pass: `happen-content-filter-first.txt` (**9 passed**).

Sampling retains delivered messages and appends developer
`<content_filter_guidance>` after each block, including the final exhausted
attempt. Catalog text must be nonblank and at most 512 UTF-8 bytes; invalid text
falls back to Codex's complete permitted-alternative guidance, not a truncated
instruction. Content-filter blocks share the existing stream retry budget.
Compaction retries do not inject sampling guidance. Tool calls from failed
streams remain unadmitted and unexecuted.

The network owner waits for the agent's durable admission acknowledgement over
the same ordered channel as delivered output. Independent SQLite reads at the
next outbound request verify that this is not merely an in-memory retry-body
change. Both successful recovery and exhausted recovery preserve all guidance
and delivered text across restart and later inference. This batch does not
complete the broader provider/client or compaction inventory.

A further cancellation regression reproduced an indefinite wait for host
admission after the caller cancelled (`happen-content-filter-cancellation-baseline.txt`).
The admission wait now uses the same caller cancellation as the response stream;
a delayed host cannot keep the caller blocked or cause another model request.
The final retry/content-filter/stdio run passed **103 tests**, including that
regression (`happen-content-filter-final-focused.txt`). The subsequent full
backend rerun passed **799 tests / 2 explicit skips** in
`happen-backend-current.txt`.

## Remaining verification and implementation work

- Keep rerunning the complete backend checks and the outbound-request E2E matrix
  as the remaining ports land. The current serial backend and all 46 context
  cases pass; preserve every matrix case and strict request equality.
- Finish a case-by-case upstream coverage inventory. JSONL partial records,
  compression, split storage homes, rollout migration and
  projection cancellation are not all covered by the current SQLite tests.
  SQLite atomic rows remove some JSONL failure modes, but import and lineage
  behavior still need independent evidence.
- Live unified-exec command items and their launch/background lifecycle are
  ported (five cases passed). Agent-invoked CLI execution is in scope; desktop
  terminal presentation is not. Complete file/image/sleep live-item coverage and
  broader live-item coverage remain to be finished. The completion-queue budget
  port exposed an extra commit on intervening streaming records (one instead of
  zero) in both tool-result and cancellation variants before the batching fix.
- Complete the broader applicable provider/client, compaction and token-record
  inventory. Content-filter recovery now has executable ports and durable-host
  proof above; those nine cases are not a blanket agent-loop completion claim.
- Core MCP stdio/URL pooling ports are in progress; plugins are excluded.
  The case-by-case [MCP inventory](mcp-port.md) separates ports, adaptations and
  remaining ordinary transport/OAuth contracts.
  The sole MCP reference is Codex, including global/local config behavior; the
  sharing adaptation keys stdio ownership by command/arguments, cwd and env.
  The 26 ordinary OAuth discovery cases all failed before the corresponding
  implementation changes; the focused OAuth/pooling/config/transport siblings
  subsequently passed 58 cases. The expanded discovery/HTTP matrix separately
  exposed 38 failures (19 cases already passed) before its implementation port.
  These counts are bounded evidence, not complete MCP-suite coverage.
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
  queued T3Code workspace presentation. Migrate and triage the failing desktop
  fixtures against native thread/items before claiming the full check passes;
  do not restore retired APIs to satisfy them. Backend completion takes priority.
- Hot reload/live probing requires an available debug app and DTD. Offscreen
  tests must not interrupt the human's desktop.
