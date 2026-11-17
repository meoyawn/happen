# Command session reclamation

Modified Dart port of OpenAI Codex, Copyright 2025 OpenAI, Apache-2.0.
Source revision: `ee344ca9458351a6ea102795fa73110ad3ede5dc` in
`../codex`. Paths below are relative to `codex-rs/`.
See [license](tools/CODEX-LICENSE) and [notice](tools/CODEX-NOTICE).

`lib/src/tools.dart::HostTools` adapts the policy in
`core/src/unified_exec/process_manager.rs` and the 64-process soft cap in
`core/src/unified_exec/mod.rs`. The eight most recently used sessions are
protected. Among older sessions, reclaim the oldest exited session first,
otherwise the least recently used live session. Evicting a live session invokes
the existing process supervisor's termination, including its process group.
Recency uses an owner-local sequence instead of a wall clock.

Writes and polls hold the existing per-command interaction guard. Exited
sessions remain protected while their output closes or their completion event
is being acknowledged. If an exited candidate is still busy, the store may
temporarily exceed the soft cap instead of terminating live work. Commands are
admitted after successful process creation, so invalid launches cannot evict a
session.

The previous 32-entry rejection counted exited, uncollected sessions and could
abort an awaited JavaScript tool sequence. Capacity now triggers reclamation.
Other host failures retain Codex's promise-rejection behavior: JavaScript can
catch them, and an uncaught rejection still fails the cell. This policy belongs
to the host command owner; the embedded QuickJS runtime is unchanged.

## Applicability and tests

`../../test/command_sessions_test.dart` uses the public OpenAI tool runtime,
real shell processes, completion events, stdin and FIFOs. It adds no production
test configuration or injected process store.

| Upstream case in `core/src/unified_exec/process_manager_tests.rs` | Dart coverage |
| --- | --- |
| `pruning_prefers_exited_processes_outside_recently_used` | Adapted: fill 64 sessions, independently finish an older session, admit a command through JavaScript, and verify the exited session is reclaimed while the older live session survives. |
| `pruning_falls_back_to_lru_when_no_exited` | Adapted: polling renews recency, three awaited JavaScript commands succeed at capacity, and the evicted live process terminates. |
| `pruning_protects_recent_processes_even_if_exited` | Adapted: an older live session is evicted while a recent exited session retains its output and exit status for a later poll. |
| `pruning_does_not_evict_live_process_while_exited_process_is_finalizing` | Adapted: hold a real completion-event acknowledgement, admit another process, then release completion and verify the exited session becomes reclaimable. |
| Interaction-lock exclusion in `prune_processes_if_needed` | Additional runtime coverage: an active poll remains protected after becoming least recently used; cancelling observation leaves the process available. |

Remote executors, network-approval cleanup, sandbox policy and plugin metrics
are excluded because these are absent from Happen's command runtime. Local
verification on macOS does not establish Linux or Windows parity. FIFO and
POSIX-process cases are skipped on Windows.

## Verification on November 15, 2026

All five regressions first failed on the unchanged implementation with
`Too many running command sessions`. After the port, all **18 focused tests**
passed, and focused analysis reported no issues:

```sh
moon run happen:test-unit -- test/command_sessions_test.dart test/tool_interfaces_test.dart test/tool_cancellation_test.dart --concurrency 1 --reporter expanded
moon run happen:analyze -- packages/openai/lib/src/tools.dart test/command_sessions_test.dart
```

Dart MCP hot reload succeeded. An independent `HostTools` in the running app
started 64 sessions, admitted another command with exit 0, verified eviction of
the oldest session, and exchanged stdin with a surviving session. Its processes
were closed and its temporary directory removed without interacting with the UI.
