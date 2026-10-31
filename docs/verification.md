# Verification procedure

Verify the behavior selected in [decisions.md](decisions.md). Record reproducible,
sanitized results in `docs/evidence/`, including source revision, commands,
operating system, architecture, Dart version, model, effort, and API route.

## Local checks

Run `dart analyze`, `dart test`, and `git diff --check`. Do not run `dart format`
(see `AGENTS.md`); preserve existing Dart formatting. Run focused tests while developing, then the
complete repository suite after integration.

Use `git submodule update --init --recursive` and `dart pub get` first in a fresh
checkout. See [api.md](api.md) for configuration and the public API.

- Static analysis, whitespace checks, and focused behavior tests. Exercise actual transport,
  storage, tool, and WebSocket boundaries; avoid tests that repeat implementation.
- Verify streaming tool calls, provider state after save/load, append-only GPT
  effort updates, fixed DeepSeek effort, cancellation, incomplete streams, restart,
  independent forks, and validated export/import.
- Run `dart test test/server_test.dart test/gpt_test.dart -r expanded` for active
  turns outliving RPC deadlines, simulated 24/48/72-hour observation, legacy step
  limits, queued follow-ups, and GPT's five-minute event idle limit and bounded
  stream recovery over HTTP/SSE and WebSocket. Check cancellation during backoff
  and that recovery does not repeat executed tools. Accelerated clocks keep these
  regressions short; real server/network/agent/storage owners handle the work.
  Run `dart run tool/verify_long_turn.dart` separately for two real-time model
  responses lasting 606 seconds. Both must finish durably, without retries or
  retained task owners. It uses local provider fixtures and temporary data.
- Verify global MCP processes are shared across tasks and supervised; task
  cancellation must not terminate unrelated calls or the shared server.
- Run `dart test test/file_search_test.dart test/server_test.dart -r expanded`
  for server-side file/directory search, exact directory priority, Git exclusions,
  plain folders including empty directories, bounded results,
  cancellation and out-of-order replies over UDS, and 100 simultaneous task
  streams with searches on the same WebSocket. The streaming fixture withholds
  event acknowledgements, checks that search replies still pass and buffered
  events retain their per-task order, then verifies bounded backlog disconnection.
- Run `flutter test --no-pub packages/desktop/test/view_test.dart -r expanded`
  for new/existing draft mentions, folder selection, debounce, keyboard/tap selection, caret and
  suffix preservation, late replies, IME/email input, retry, task switches, and
  disconnect cancellation. The geometry regression checks that the composer,
  conversation viewport and reading scroll position stay fixed while the popup
  loads, changes between 1/20/0 results, fails, and closes.
- Run `dart test test/server_tools_test.dart` for append-only GPT declarations
  after config edits during active and idle tasks, direct and code-mode calls,
  invalid edits, removals, and catalog restoration after compaction and restart.
  It also stops the server before editing config, restarts it, and resumes tasks
  after tool additions, changes, and removals. A task with no previous MCP tools
  is stopped during an active model response and resumed first after restart.
- Run `dart test test/config_test.dart test/config_reload_test.dart test/mcp_test.dart`
  for YAML validation, legacy fallback, automatic reloads through real file saves,
  process replacement/removal, unchanged subscriptions, rapid edit/revert, and
  URL connection changes without managing the remote server process.
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

Run `flutter test --no-pub packages/desktop/test --reporter expanded` for desktop
streaming, nested tools, project identity changes, settings persistence, account
controls, keyboard input, archive/restore, and toast expiry. `moon run dev` verifies
the actual macOS build; use the Dart MCP hot-reload/runtime-error tools against
that app's VM service. Native menu and browser return behavior also need a native
build. Fixture tests must not sign out or replace the user's live credentials.

For attachments, run `dart test test/attachments_test.dart test/server_test.dart
test/deepseek_test.dart --reporter expanded` and `flutter test --no-pub
packages/desktop/test/session_test.dart packages/desktop/test/view_test.dart
--reporter expanded`. The server fixtures exercise a real 64 MiB-plus image,
large acknowledged blocks, connection ownership, cancellation cleanup, both
Codex detail budgets, durable image history, and all provider wire formats.
The desktop fixture sends a 100 MiB source through a real TCP proxy and inspects
the actual request to prove preparation happens before the 32 MiB transport
budget. Widget tests exercise the native drop event adapter, clipboard channel,
draft retention, attachment cleanup and ordinary text paste.

## Live comparisons

Use the installed Codex CLI as the GPT reference. Keep the model and effort equal,
give each harness a fresh copy of the same task/workspace, and disable skills,
plugins, and unrelated configuration for both. Use an existing authorized login
without printing, copying into history, or rotating another client's credentials.
Check the resulting files and executable behavior independently. Report success,
tool failures, latency, token usage, and cache usage separately; a successful answer
is not evidence of a cache hit or equivalent task quality.

Run `dart run tool/verify_live.dart` with an existing Codex login. An optional
positional argument selects its authentication file. The script creates isolated
temporary workspaces, runs Happen over both GPT model transports and the installed
Codex CLI, and independently checks the resulting CSV processing program. It
prints sanitized JSON evidence and exits nonzero if artifact checks fail.

Use the local OpenCode checkout and the supported DeepSeek route for the requested
DeepSeek comparison. Verify the available route and its usage conditions before
running. If direct access from this harness is unavailable, distinguish that
limitation from tests of the adapter using recorded or local protocol fixtures.
Never label a local fixture run as live model verification.

For OpenCode Console, run `dart run bin/agent.dart login --provider opencode` and
approve the device in the signed-in browser. Select provider `opencode` and the
exact model `deepseek-v4.1-flash-free`, as shown in
[api.md](api.md). Check authentication independently from inference. The package
owns its credentials; do not copy the OpenCode CLI's tokens into Happen.

Start with `dart run bin/agent.dart exec --provider opencode --reasoning low
"Reply READY only. Do not use tools."`. Compare with
`opencode run --standalone --log-level none --model
opencode/deepseek-v4.1-flash-free#low --format json "Reply READY only. Do not use tools."`
using the CLI's independent login. If both succeed, repeat the isolated CSV task
above and independently verify its files. If the service returns a quota or
client-access denial, record the status and safe error category, respect its
retry interval, and stop that live route check. A CLI success alone does not
establish that Happen can use the hosted route. Do not change to a paid model or
identify Happen as another application to alter that outcome.

For compaction, preserve multiple known facts and unfinished actions, compact,
continue, retrieve an omitted historical tool result, and repeat after restart and
fork/import. Exercise the HTTP/SSE and upstream WebSocket routes separately where
implemented. Measure reported cache usage with a warmed, sufficiently long prefix;
keep the initial GPT effort fixed while appending an effort change. Compare an
unchanged-effort continuation to the changed-effort continuation.

Run `dart run tool/verify_context.dart` for the live server path. It records a
random tool receipt, leaves an action unfinished, changes effort, compacts, restarts
the server, forks and exports/imports the task, then asks the model to retrieve the
old receipt through history tools and finish the action. It checks the resulting
file, instruction retention, native checkpoint, stable historical event, and
reported cache usage for both model transports. Its optional positional argument
also selects the Codex authentication file. This is a short functional check;
repeated runs and larger tasks are needed to characterize recall or caching.

`tool/verify_compaction.dart /path/to/agent-data` retains the smaller direct
Responses protocol probe used for the initial native-compaction evidence.

Run `dart run tool/verify_mcp_tools.dart` from this checkout with an existing Codex
login to verify config-driven tools over both GPT transports. The optional
positional argument selects the authentication file. Each task starts without
MCP tools, adds the real Dart MCP and a local probe through a temporary config,
then calls the newly declared probe directly. Checks compare the returned PID
with the supervised process and inspect persisted tool declarations. Credentials
remain private references, and the temporary config and processes are removed.

## Runtime measurements

Run `dart run tool/bench_runtime.dart` for the JIT baseline. Also compile and run
the benchmark as an AOT executable, accounting for native build-hook assets.
Measure a sustained 100-cell/second workload, concurrent tasks, a blocked SQLite
operation, heartbeat intervals, RSS, and native thread count. Preserve raw results
and distinguish throughput, startup bursts, allocator retention, and live memory.
Measurements apply to the recorded environment; they are not capacity guarantees.

The executable bundle must include the libraries produced by the native build
hooks. Run JIT and AOT measurements sequentially to avoid mutual CPU interference:

```sh
ulimit -n 4096
dart run tool/bench_runtime.dart > /tmp/happen-runtime-jit.json
dart build cli --target=tool/bench_runtime.dart --output=/tmp/happen-aot-bundle
/tmp/happen-aot-bundle/bundle/bin/bench_runtime > /tmp/happen-runtime-aot.json
```

The sustained phase schedules 1,000 cells at 100 cells/second across 100 active
agents and writers, with one SQLite commit per cell. It lasts about ten seconds.
The separate burst phase runs while one additional SQLite owner executes a long
recursive statement. Heartbeat measurements distinguish those phases. A longer
soak and other machines are separate measurements.
