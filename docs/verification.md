# Verification procedure

Verify the behavior selected in [decisions.md](decisions.md). Record reproducible,
sanitized results in `docs/evidence/`, including source revision, commands,
operating system, architecture, Dart version, model, effort, and API route.

## Local checks

Run `dart format --output=none --set-exit-if-changed bin packages test tool`,
`dart analyze`, and `dart test`. Run focused tests while developing, then the
complete repository suite after integration.

- Format, static analysis, and focused behavior tests. Exercise actual transport,
  storage, tool, and WebSocket boundaries; avoid tests that repeat implementation.
- Verify streaming tool calls, provider state after save/load, append-only GPT
  effort updates, fixed DeepSeek effort, cancellation, incomplete streams, restart,
  independent forks, and validated export/import.
- Verify global MCP processes are shared across tasks and supervised; task
  cancellation must not terminate unrelated calls or the shared server.
- Verify compaction preserves full searchable history, and failed/cancelled
  compaction leaves the active context intact.
- Compare live ChatGPT execution with installed Codex using the same model and
  effort, isolated workspaces, and no skills/plugins. Verify completed artifacts,
  rather than relying on the model's report of success.
- Verify DeepSeek through the available OpenCode checkout and supported route;
  distinguish adapter checks from a live route that is unavailable or restricted.
- Record AOT measurements and sustained 100-cell/second behavior alongside the
  existing JIT evidence. Record environment and commands with results.
- Keep credentials out of output, telemetry, history, and evidence artifacts.

## Live comparisons

Use the installed Codex CLI as the GPT reference. Keep the model and effort equal,
give each harness a fresh copy of the same task/workspace, and disable skills,
plugins, and unrelated configuration for both. Use an existing authorized login
without printing, copying into history, or rotating another client's credentials.
Check the resulting files and executable behavior independently. Report success,
tool failures, latency, token usage, and cache usage separately; a successful answer
is not evidence of a cache hit or equivalent task quality.

Use the local OpenCode checkout and the supported DeepSeek route for the requested
DeepSeek comparison. Verify the available route and its usage conditions before
running. If direct access from this harness is unavailable, distinguish that
limitation from tests of the adapter using recorded or local protocol fixtures.
Never label a local fixture run as live model verification.

For compaction, preserve multiple known facts and unfinished actions, compact,
continue, retrieve an omitted historical tool result, and repeat after restart and
fork/import. Exercise the HTTP/SSE and upstream WebSocket routes separately where
implemented. Measure reported cache usage with a warmed, sufficiently long prefix;
keep the initial GPT effort fixed while appending an effort change. Compare an
unchanged-effort continuation to the changed-effort continuation.

## Runtime measurements

Run `dart run tool/bench_runtime.dart` for the JIT baseline. Also compile and run
the benchmark as an AOT executable, accounting for native build-hook assets.
Measure a sustained 100-cell/second workload, concurrent tasks, a blocked SQLite
operation, heartbeat intervals, RSS, and native thread count. Preserve raw results
and distinguish throughput, startup bursts, allocator retention, and live memory.
Measurements apply to the recorded environment; they are not capacity guarantees.
