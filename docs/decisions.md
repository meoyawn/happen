# Technical decisions and evidence

This is the decision record for this agent server. Measurements are observations on the
listed environment, not capacity guarantees. Update entries as evidence changes.

## 2026-10-29 — Priorities and storage ownership

Priority order: hundreds of concurrent tasks, occasional reasonably efficient
forks, then reliable portable history. Forks and transfers may take time.

Each task/branch has a self-contained SQLite database. Immutable history and
small execution metadata commit together. Forks copy a committed historical
prefix into a staged independent database. Imports validate a versioned bundle
and checksum before publishing an idle task. Neither operation executes history.
Canonical history is preserved through compaction.

Reason: task writes do not contend for one SQLite writer; deleting a parent does
not invalidate children. Copied history costs disk and fork latency, acceptable
given the stated priorities. A shared database might also meet the throughput
target; no benchmark has established otherwise.

References inspected: Codex thread-store live_writer.rs (paginated appends await
SQLite projection), Pi Coding Agent session-manager.ts (full history in RAM),
Pi Durable storage/sqlite/storage.ts (paged reads and inherited prefixes), and
OpenCode session/projector.ts (copied settled history within its projection
transaction). These are distinct implementations, not interchangeable claims
about “Pi” or “SQLite”.

## 2026-10-29 — Isolates and native threads

Decision: one agent isolate plus a dedicated SQLite owner isolate per active task.
All requests and commit acknowledgements use SendPort/ReceivePort messages.
The writer serializes its mailbox with await-for. There are no application
mutexes. SQLite retains its internal transaction/WAL synchronization.
The server and network isolates never execute task SQL.

An isolate is an independent heap/event loop, not a permanently pinned OS thread.
Native calls execute on OS threads. sqlite3 3.8.0 declares sqlite3_step,
sqlite3_exec and sqlite3_prepare_v3 as non-leaf FFI calls. QuickJS calls also remain
non-leaf so the VM can schedule other isolates while native code runs.
Do not mark potentially blocking or JS-executing functions isLeaf.

Evidence: macOS arm64, 10 logical CPUs, Dart 3.13.7, JIT, bundled SQLite,
WAL + synchronous=FULL, 512 KiB suggested SQLite page cache per database.
Command:

    dart run tool/bench_runtime.dart

Raw result: [initial runtime benchmark](evidence/runtime-jit-initial.json).

- 100 agent + 100 writer isolates started in 218 ms.
- RSS increased about 28.8 MiB after creating those isolates and databases.
- The process had 30 OS threads; JS ran on 17 observed thread IDs.
- An extra SQLite isolate ran a single recursive INSERT for 2,789 ms.
- All 100 other agents finished while that native SQL operation was running.
  The 99 ordinary agents finished in at most 508 ms; each executed 20 fresh JS
  cells, awaited host work, and persisted 20 SQLite transactions.
- The 10 ms server heartbeat had 59.6 ms p99 / 76.9 ms max intervals during
  startup/burst work. This is visible jitter, not a hard realtime guarantee.
- Whole-process peak RSS was about 403 MiB including Dart JIT and the benchmark.
  Post-cleanup RSS stayed above the initial baseline; allocator retention and JIT
  costs must not be confused with live session memory.

This supports message-based ownership without pinning a native thread per
session. It does not prove behavior under pathological disk stalls, swapping, or
all 100 SQLite writers simultaneously blocked. More hardware and AOT measurements
are still needed. The slow INSERT occupies native execution without introducing
an application lock or synthetic sleep.

## 2026-10-29 — QuickJS lifecycle

Decision: fresh QuickJS runtime and context per cell, disposed after host calls
settle. Store/load values live outside the JS context and are persisted explicitly.
No interpreter process, Flutter plugin, Rust bridge, or V8 dependency.
The C engine is shared executable code; contexts are independent native state.

The public package is code_mode. QuickJS is its private engine implementation;
the agent depends on cell execution, host calls, and explicit state, not engine APIs.
Use upstream QuickJS 2026-06-04 via a small handwritten C ABI and Dart FFI.
The source archive and hash are recorded in packages/code_mode/native/UPSTREAM.md.
Dart's build hook compiles the library. The bridge refreshes QuickJS's stack-top
pointer on entry because an owning Dart isolate can execute on different OS
threads over time.

The same JIT benchmark measured 1,000 cells including bootstrap and disposal:

| Lifecycle | Median | p99 | Total for 1,000 |
| --- | ---: | ---: | ---: |
| Fresh runtime + context | 232 us | 507 us | 266 ms |
| Retained runtime + fresh context | 191 us | 406 us | 206 ms |

The ~41 us median saving does not justify reusing runtimes at a 100 cells/second
target. This is a small-cell measurement; large sources and allocations cost more.
Async host waits are event-driven, not a 1 ms polling loop. Concurrent contexts
still consume memory; cells have memory, CPU, wall-time, output, and host-call
limits. QuickJS is not an OS security sandbox.

## 2026-10-29 — Shared asynchronous networking

One network isolate owns one HttpClient/connection pool and the OAuth manager.
Agent isolates send requests and receive streaming events/results through messages.
The client object cannot itself cross Dart isolate heaps. Credential refresh is
coalesced by a future in its owner; no application mutex is used.

Tradeoff: messages copy model input between isolate heaps. Inputs and history
pages are bounded. Measure this cost before adding transferable encodings.

## 2026-10-29 — Login and dependencies

Pi and OpenCode's Codex login both use the same public Codex OAuth client with
PKCE. The auth package implements the standalone browser/device flow with Dart HTTP and
crypto. The login --from-codex option stores a path reference, reads access tokens,
and never rotates or writes Codex's credentials. Independent login owns
its refresh token. Credentials are written with private permissions.

Use sqlite3 3.8.0 directly: synchronous FFI, no ORM or asynchronous database
framework. Use dart:io WebSockets and HTTP; no server framework.
Resolved dependency versions are committed in pubspec.lock.

## 2026-10-29 — Telemetry and diagnostics

No runtime logging or telemetry exporters. A tiny package maintains fixed-name
counters and bounded timing buckets; no prompt, token, source, or tool-output
attributes. Snapshots are requested through the protocol. CLI output is the
requested agent result, not a background logging stream.

Benchmark reports and this decision record are deliberate evidence artifacts,
distinct from runtime logging.

## 2026-10-29 — Upstream dependency management

QuickJS is a Git submodule pinned to upstream release commit
3d5e064e9dd67c70f7962836505a7fa067bf0a4e. The interpreter source matches the
previously benchmarked 2026-06-04 archive byte-for-byte. Do not copy the upstream
source into this repository or float the submodule on a branch. Only the thin
bridge belongs to this project.

## 2026-10-29 — Codex tool contract

Optimize the tool interface for GPT models by preserving the Codex names and
namespaces. The model-visible entry point is functions.exec, a custom tool with
raw JavaScript input and Codex's Lark grammar. It returns custom_tool_call_output.
Within cells, expose tools.exec_command, tools.write_stdin, and tools.apply_patch.
Preserve shell argument keys, output/session_id/exit_code/wall_time_seconds, and
the raw patch string input. No alternate read_file/write_file/code tool names.

Source: local Codex 0.164, core/src/tools/code_mode/execute_spec.rs,
core/src/tools/handlers/shell_spec.rs, tools/src/responses_api.rs, and
protocol/src/models.rs. No claim of complete runtime parity: PTYs, permission
escalation, image tools and yielded-cell functions.wait are not advertised.

## 2026-10-29 — Model and reasoning changes preserve the prompt prefix

User decision: keep the model fixed for each task; allow append-only GPT effort
changes. DeepSeek effort is fixed for each task (see the 2026-10-30 decision below).
OpenAI documents configuration_update for effort changes in standard single-agent
GPT-6 conversations. Keep the initial top-level reasoning.effort fixed, retain the
updates in their original history positions, and append an update before the next
user message. Adjacent updates are rejected by the API.

Configuration updates change only effort. The docs do not establish cross-model
cache reuse; do not promise it or silently switch model weights. Preserve initial
instructions and tool schemas/order as task data. Track cached_tokens and total
input_tokens so cache effectiveness can be measured instead of assumed.

Preserving the initial tool catalog does not prohibit adding an MCP mid-thread.
The current Responses API documents developer-role additional_tools input items
for appending tool declarations, and developer messages can append instruction
changes. Codex's context/world_state/top_level_tools.rs already emits
ResponseItem::AdditionalTools for tool deltas. Keep those updates at their original
history positions. Connecting/authenticating an MCP and routing its calls are
separate host capabilities. The initial scope now includes global MCP servers
(see the 2026-10-30 requirement below), using this incremental path.

Source: [tool loading](https://developers.openai.com/api/docs/guides/tools-tool-search)
and the prompt-caching guide's Manage tools with append-only updates section.

Automatic compaction/truncation and the standalone compact endpoint are
incompatible with these updates. Explicit compaction is a cache boundary and must
restore the effective effort in the new context.

Sources, read 2026-10-29:
[Reasoning updates](https://developers.openai.com/api/docs/guides/reasoning#change-reasoning-mid-conversation)
and [prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching).

## 2026-10-30 — Initial MCP scope (user requirement)

The initial implementation must support MCP servers declared in global config,
both remote URLs and local subprocess commands. Local servers are supervised
globally by the harness and shared across tasks, rather than launched once per
conversation. URL servers require connection management, not child-process
supervision. Per-project and per-task MCP declarations are outside this initial
scope. Implementation and lifecycle verification remain outstanding.

## Protocol verification, 2026-10-30

The ChatGPT subscription endpoint accepted native compaction via a
compaction_trigger item with an earlier configuration_update on gpt-6.1-sol.
Continuation from the returned compaction item, with the original top-level
effort unchanged and a fresh effort update, recalled the three test facts.
This is protocol evidence, not a decision selecting a compaction strategy or a
long-context quality/cache benchmark. All three requests had zero cached tokens.

Evidence: [native compaction smoke test](evidence/native-compaction-smoke.json).
Reproduce with an existing login:

    dart run tool/verify_compaction.dart /path/to/agent-data

## 2026-10-30 — History retrieval (user requirement)

Long-task recall must support targeted access to durable conversation history
from code mode. The user's reference shows a cell paging through session messages
and tool inputs/results, selecting regex matches, and returning short excerpts
with message IDs and timestamps:
[OpenCode history retrieval example](https://x.com/thdxr/status/2114754693255602450).

Compacted-away events must remain queryable. History access needs bounded pages
and bounded output, with stable references that survive fork/export/import.
The SQLite owner continues to own all reads; filtering in code mode must not
require loading the complete transcript into the agent isolate or model context.
The exact exposed tools must follow the pinned Codex contract.

The user reaffirmed this requirement when selecting Codex-style compaction below.
History retrieval is shared across labs and works independently of whether the
active context contains an opaque native compaction item or a clear-text summary.
Retrieval implementation and long-task recall measurements remain outstanding.

## 2026-10-30 — DeepSeek effort is fixed per task

User decision: select DeepSeek reasoning effort when creating a task and reject
effort changes during that task. Config changes must not alter an existing task's
effort. GPT retains its append-only configuration_update behavior.

Tradeoff: DeepSeek tasks cannot adapt their effort mid-task. This removes the
initial implementation's dependency on an unverified cache-preserving effort
override. It does not establish cache-hit parity with GPT.

Basis: explicit user decision on 2026-10-30; this is a policy decision, not a new
runtime measurement. The DeepSeek package and enforcement remain unimplemented.
The published V4.1 format supports later system messages, but hosted-route
behavior, cache reuse, and instruction precedence remain to be investigated in
[issue #1](https://github.com/meoyawn/happen/issues/1), which includes the source
reference and required reproduction evidence. That investigation does not change
the fixed-effort policy.

## 2026-10-30 — Shared Codex tool interface, including code mode

User decision: use Codex's tool interface, including code mode, for both GPT and
DeepSeek. The canonical tool catalog, argument contracts, result fields, editing
semantics, and code-mode execution behavior are shared. Preserve functions.exec
and the nested tools.exec_command, tools.write_stdin, and tools.apply_patch
contracts. New exposed capabilities must follow the pinned Codex source.

Lab packages own API-required encoding of that shared interface. GPT preserves
native namespaces and freeform inputs; another API may require an outer encoding
adaptation. This does not create a separate tool implementation or lab-specific
catalog. Authentication, API serialization, reasoning configuration, and compaction
mechanisms remain provider concerns. Compaction and the shared conversation-record
boundary are selected below; concrete Dart types will follow during implementation.

Basis: explicit user acceptance after reviewing same-model harness evaluations.
The [NTU study](https://arxiv.org/html/2610.00917v1) reports GPT-6 Astra passing
38/63 terminal tasks with Pi versus 35/63 with Codex. The published 6,204 task
records were re-aggregated with Python 3 on macOS arm64 on 2026-10-30; those counts
match. The [task-level dataset](https://huggingface.co/datasets/yixuanli97/finding-the-right-fit/blob/main/results/task_level.tsv)
allows reproduction by grouping reward by model, benchmark, and harness, retaining
the study's fixed denominators and unresolved-zero outcomes.

[Harness-Bench v2](https://arxiv.org/html/2605.27922v2) reports DeepSeek V4 Pro and
Flash attaining their highest mean general-task score with Codex among seven
tested harnesses. These are complete-harness comparisons, not isolated tests of
tool naming, editing formats, or JavaScript code mode. They support interoperability
and do not prove that this exact shared interface is optimal.

Tradeoff: one contract reduces implementation and maintenance divergence, but may
leave model-specific performance gains unrealized. Any future presentation variant
needs a controlled comparison on the target model and workload. Code-mode-only
quality, current-model performance, and the DeepSeek wire adaptation still need
verification. This decision does not assert full Codex runtime parity; advertise
yielded-cell functions.wait and other missing capabilities only after implementing
their behavior.

## 2026-10-30 — Codex-style compaction and shared history retrieval

User decision: follow Codex's compaction behavior and keep the implementation
simple. GPT native compaction belongs in packages/gpt. Leave room for clear-text
DeepSeek compaction in packages/deepseek through the same shared operation; do not
require all providers to return an encrypted GPT compaction item.

For GPT, use the explicit compaction_trigger path through the ordinary Responses
transport. Preserve the returned native compaction state and required retained
context; restore effective reasoning effort as already documented. Support manual
compaction and harness-triggered compaction based on context usage, with bounded
overflow recovery. The initial implementation can pause generation during
compaction; background speculative compaction is not required for this scope.
This is an implementation-scope interpretation of the user's simplicity request,
not a claim of full Codex feature parity.

The shared agent coordinates compaction and persistence. A successful compaction
appends a durable checkpoint and changes the active context; original conversation
events remain available for recall, fork, and export. Failed or cancelled compaction
must not replace the active context. Existing isolate ownership remains unchanged.

The history-retrieval example is also part of the initial scope: code mode can
read bounded portions of the durable transcript, inspect message text and tool
inputs/results, filter them in JavaScript, and return only selected excerpts with
stable references. This is shared storage/tool functionality, independent of the
lab compactor. Start with ordinary history reads and text search; embeddings and
a separate semantic-memory service are not needed for the requested behavior.
Keep Codex's tool contracts when exposing the capability.

Source inspection on macOS arm64, 2026-10-30:

- Codex commit 2681f8cba2831ef72bca2c0672b2e49d5f690745:
  core/src/tasks/compact.rs selects native v2 or textual compaction by provider
  capability. core/src/compact_remote_v2_attempt.rs appends compaction_trigger;
  core/src/compact_remote_v2.rs sends the request, validates the result, and builds
  retained context. Paths are relative to codex-rs/.
- OpenCode commit fa96f42f6cd8bf21f11fd5b38d78e2dd34d5563e:
  packages/core/src/session/store.ts reads ordered message pages anchored by IDs
  and sequence numbers; packages/core/src/session/history.ts builds active context
  using compaction boundaries. The screenshot's exact session_context tool name
  was not present in this checkout, so the screenshot establishes the requested
  interaction while the source establishes the underlying storage behavior.
- Re-read the [user's reference](https://x.com/thdxr/status/2114754693255602450)
  through the Twitter CLI and inspected its image. Reproduce the source reads with
  git show COMMIT:PATH in the corresponding repository. Reproduce the post read
  with go run . posts read https://x.com/thdxr/status/2114754693255602450 from the
  Twitter CLI repository, after go run . --help.
- The existing native-compaction smoke test above verifies the ChatGPT subscription
  HTTP/SSE route with three retained facts. It does not verify the WebSocket route,
  repeated compactions, cache performance, or long-task recall.

Tradeoffs: native GPT state is opaque and provider-specific; textual DeepSeek
summaries are inspectable but can omit details. Targeted retrieval can recover
omissions when the agent looks for them, but does not guarantee that it notices
every omission. Runtime integration and end-to-end recall verification remain
outstanding; this entry records the selected design, not completed implementation.

## 2026-10-30 — Shared conversation records with provider-specific state

User decision: follow Pi and OpenCode's approach to conversation storage and
construction of subsequent model requests.

Persist a shared conversation format in the existing per-task SQLite history:
messages and content parts, tool calls/results, and ordered configuration and
compaction events. Keep provider-specific state attached to the relevant record
or part. Shared code can read text, tool inputs/results, identifiers, timestamps,
and usage without understanding a provider's API. The lab package converts these
records into its request format and converts responses into the shared format.

The shared format must retain the state needed by each supported provider, such
as message/item and call IDs, message phases, reasoning signatures or encrypted
reasoning, and native compaction state. Preserve custom-tool input strings and
namespaces as required by the selected Codex tool contract. GPT effort/tool updates
keep their original positions. A text compaction summary and an opaque provider
checkpoint both fit this design. Required provider state must survive persistence,
restart, fork, and export/import without being converted to ordinary visible text.

This selects shared semantic records with provider-specific fields, rather than
making complete Responses API items the general-purpose persisted message format.
It supersedes the earlier conversational recommendation to use native items as the
primary message payload. Building a subsequent request from history never executes
the recorded tools. The storage backend and isolate ownership stay as previously
selected; Pi's JSONL persistence is not part of this decision.

Evidence inspected on macOS arm64, 2026-10-30:

- Pi commit e7a0df27c09d11bf4161d3605246cbf57a129cb2:
  packages/ai/src/types.ts defines shared message/content types with provider/model
  identity and fields such as thinkingSignature and textSignature.
  packages/coding-agent/src/core/session-manager.ts wraps AgentMessage in a session
  entry and writes it as JSONL. packages/ai/src/api/openai-responses-shared.ts
  rebuilds API items from those messages; it preserves complete reasoning items in
  thinkingSignature and message IDs/phases in textSignature. This evidence is from
  the Pi Coding Agent path, not a claim about Pi Durable's storage implementation.
- OpenCode commit fa96f42f6cd8bf21f11fd5b38d78e2dd34d5563e:
  packages/schema/src/session-message.ts defines shared messages/content parts with
  optional native fields. packages/core/src/session/projector.ts persists those
  records and parts in SQLite. packages/core/src/session/runner/to-llm-message.ts
  converts them into common AI messages carrying provider metadata; provider
  protocols then produce API-specific requests. Native compaction can retain a
  replacement context through native.messages alongside the summary field.
- DeepSeek Harness commit ce7073d51254c26cd63b22a60835b8f948deb447, inspected at
  the user's additional request:
  packages/llm/llm/src/message.ts defines shared roles/content and attaches
  provider/model identity plus adapter-private replayState to assistant messages.
  packages/core/session/src/types.ts persists these in assistant/message events.
  packages/llm/llm/src/types.ts separates response-level and per-block provider
  metadata. The native DeepSeek adapter's packages/llm/llm-deepseek/src/replay.ts
  retains block types and thinking signatures without duplicating response text;
  serialize.ts combines that state with the shared content to construct a
  DeepSeek Messages API request. This supports the same record/adapter boundary;
  reading its serializer does not establish live API behavior or cache efficiency.

Reproduce source inspection in each checkout with git show COMMIT:PATH, using the
commits and paths above. The inspected implementations share this pattern but
have different schemas, persistence backends, and conversion details.

Tradeoff: adapters must deliberately preserve provider fields and ordering; a
common format alone does not guarantee fidelity. It gives storage, retrieval, and
the agent loop one useful representation while leaving API details in lab packages.
The current prototype still stores Responses-shaped items. Migration and checks
that saved/reloaded records produce equivalent model input, including compaction
and append-only updates, remain implementation work. No runtime behavior changed
as part of this design decision.

## 2026-10-30 — Cancellation tokens

User decision: use the cancellation_token package throughout the runtime. Version
2.0.1 is resolved in pubspec.lock. Pass its CancellationToken through asynchronous
operations, with fresh tokens for each task and shared-resource lifetime. Attach
cleanup that actually aborts requests, cancels stream reads, or terminates owned
processes; cancelling a Future alone does not stop its underlying work. A task's
cancellation must not close the shared HTTP pool or another task's MCP calls.

Evidence: cancellation_token 2.0.1 source and
[package documentation](https://pub.dev/documentation/cancellation_token/2.0.1/).
Inspected CancellationToken, Cancellable, CancellableCompleter, the asCancellable
extension, and MergedCancellationToken on macOS arm64 with Dart 3.13.7. The Dart
skill additionally requires cancellation to propagate without retries. Runtime
conversion and resource-cleanup verification are in progress.

## 2026-10-30 — AGENTS.md discovery and compaction

User requirement: support AGENTS.md throughout directory trees, follow existing
harness behavior, and use Codex as the primary reference. Use Codex's simple
hierarchical discovery: load global instructions from the harness data directory,
then walk from the nearest repository root (`.git` file or directory) down to the
task working directory. Without a repository marker, load that directory only.
Within each directory, prefer AGENTS.override.md to AGENTS.md. Parent instructions
come first; deeper instructions apply to their subtree and take precedence there.
Explicit conversation instructions retain precedence over these files.

As in Codex, the startup loader does not eagerly scan every descendant directory.
Our shared harness guidance tells the agent to find and read applicable nested AGENTS.md files
before working below its working directory or outside it. Working-directory
changes load the new ancestor chain. The automatic project instruction budget is
32 KiB, with a visible truncation notice; global instructions have their own bound.
Do not add shell-command parsing or a second filesystem tool contract for this.

Compaction must not depend on a generated summary to reproduce the automatically
loaded instructions. Persist the loaded instruction snapshot as task context,
append explicit replacement/removal messages when it changes, and restore the
current snapshot when installing a successful compaction. Put it before the last
retained user message, or before the summary/native checkpoint when no user message
remains. Keep original snapshots in durable history. Failed/cancelled compaction
does not install a replacement. Instructions read manually through shell tools
remain ordinary conversation content, as in Codex; after compaction the base
instructions still require checking applicable nested files before editing.

Evidence inspected on macOS arm64, 2026-10-30 (the four pinned repositories and
both Pi harnesses listed in the shared-record decision above):

- Codex `core/src/agents_md.rs` loads the root-to-cwd chain and selects override
  files. `protocol/src/prompts/base_instructions/default.md` defines recursive
  subtree scope and requires checking nested files. This is its default/fallback
  prompt, not proof that every model-specific template repeats that rule:
  `models-manager/models.json` has separate current model templates, and the pinned
  GPT-6.1 Sol template does not repeat the nested-file paragraph.
  `core/src/agents_md_manager.rs`
  maintains the current instruction snapshot; `context/world_state/agents_md.rs`
  emits explicit replacement/removal notices. Both textual `compact.rs` and native
  `compact_remote_v2_installation.rs` call
  `build_compaction_replacement_history`, which rebuilds initial context and inserts
  it before the last real user message or compaction item. These paths are relative
  to `codex-rs/` at commit 2681f8cba2831ef72bca2c0672b2e49d5f690745.
- Pi Coding Agent `core/resource-loader.ts` loads ancestor instruction files;
  `core/agent-session.ts` and `core/system-prompt.ts` assemble their prompt content.
  `core/session-manager.ts:appendCompaction` saves the complete current system
  message with the summary, and the context projection restores it. Paths are
  relative to `packages/coding-agent/src/`.
- Pi Durable `packages/durable/src/harness/prompt.ts:planSystemEntries` writes a
  complete current prompt/tool baseline after a compaction boundary. This is
  evidence for prompt restoration, not a separate AGENTS.md discovery implementation.
- OpenCode `packages/core/src/session/instructions.ts` records nested file
  instructions as durable synthetic messages. Deduplication checks active history,
  so files can be loaded again after their messages disappear during compaction.
  `session/compaction.ts` explicitly excludes repository instructions from the
  summary because current instructions are supplied separately.
- DeepSeek Harness `packages/context/agent-instructions/src/index.ts` checks for a
  visible baseline before each step, reloads it when absent, and adds scoped
  instructions after file-tool access. It also does not rely solely on summary text.
  The recognized tools are `read`, `write`, and `edit`; shell navigation does not
  trigger discovery. Its `packages/core/system-prompt/src/index.ts` independently
  assembles stable prompt sections and dynamic context; the loop records the latter
  as user-role snapshots. The provider serializer only encodes these records.

Reproduce with `git show COMMIT:PATH` in the pinned checkouts. The selected behavior
uses Codex's existing shell-oriented discovery and explicit context restoration;
the other harnesses corroborate keeping instructions outside lossy summaries.
Tradeoff: descendant discovery still depends on the agent following the base
prompt. Exact model compliance is not guaranteed. Integration and compaction
boundary checks are required before claiming the runtime supports this feature.

## 2026-10-30 — Model catalogs and prompt ownership

User decision: copy Codex's pinned models JSON into `packages/gpt`, embed it in
Dart, and use the selected model's prompt and metadata. Prompt selection is per
model; the lab package owns that selection. Models may share identical templates.
The shared agent adds guidance for its implemented tool contracts and AGENTS.md
behavior. Repository instruction contents remain separate scoped user context.

Keep the upstream catalog unchanged and record its revision and checksum beside
it. Generate a Dart constant from the checked-in JSON so installed/AOT programs
need no source checkout or runtime file lookup. Read defaults, context limits,
reasoning support, and base prompt text from that catalog. Freeze the resolved
prompt/settings with task creation so a catalog update cannot rewrite an existing
task's prefix. Catalog capabilities describe the upstream model; expose only the
intersection with this harness's implemented capabilities. In particular, the
catalog's images, delegation, review flows, and experimental tools are not enabled
by copying the file.

For DeepSeek, reuse the pinned harness catalog where applicable. Its
`packages/llm/llm-deepseek/src/models.ts` declares `deepseek-flash` (DeepSeek V4.1
Flash) and `deepseek-v4-pro`, with a 1,048,576-token context window. It has no Codex-
style per-model prompt text: the shipped headless profile contributes a short
model-named coding persona and feature packages contribute operational guidance.
The initial supported DeepSeek model is `deepseek-flash`; copying advisory entries
does not advertise support for additional models or images.

Source: Codex 2681f8cba2831ef72bca2c0672b2e49d5f690745,
`codex-rs/models-manager/models.json`, `src/model_info.rs`, and
`codex-rs/protocol/src/openai_models.rs`; DeepSeek Harness
ce7073d51254c26cd63b22a60835b8f948deb447, the catalog above and
`packages/bundle/headless/cordis.patch.yml`. Inspected on macOS arm64,
2026-10-30. Reproduce source reads with `git show COMMIT:PATH`; regenerate embedded
catalogs with `dart run tool/embed_model_catalogs.dart`.

Tradeoffs: vendoring gives reproducible defaults and prompts but requires deliberate
updates as upstream changes. The full catalog contains unsupported upstream
features, so package validation and shared capability guidance must remain explicit.
This decision selects catalog-backed prompts, not full parity with either harness.

## 2026-10-30 — MCP 2026-07-28 and the Events draft

User requirement: implement the current MCP protocol and explicitly implement the
MCP Events draft. The core revision is `2026-07-28`; Events is an experimental
extension, not a released core feature. Pin the core specification at
`82d60be17d75e69b350c9fe77df2e8cac202ac11` in
[modelcontextprotocol/modelcontextprotocol](https://github.com/modelcontextprotocol/modelcontextprotocol/tree/82d60be17d75e69b350c9fe77df2e8cac202ac11),
and the [Events design sketch](https://github.com/modelcontextprotocol/experimental-ext-triggers-events/blob/d5316be214be2e76e51462069c1d67e00a5a7619/docs/design-sketch-proposal.md)
at `d5316be214be2e76e51462069c1d67e00a5a7619`. Changes to this draft require a
deliberate compatibility update.

Use per-request version/client metadata, `server/discover`, Streamable HTTP and
newline-delimited stdio. Core `subscriptions/listen` delivers catalog/resource
notifications. Events separately defines `events/list`, `events/poll`,
`events/stream`, `events/subscribe`, `events/unsubscribe`, and
`notifications/events/*`. Support its event identity, opaque cursor, activation,
heartbeat, gap, termination, and cancellation semantics. Do not infer that an SDK
with generic JSON-RPC notification handling implements this extension.

Global MCP connections remain owned by the shared network isolate. Local server
processes are shared across tasks and supervised. Cancellation closes only the
owning request or subscription. Never automatically repeat a tool call after a
transport failure: a lost reply does not prove the side effect did not happen.
Bound messages, catalogs, pending work, and subscriber queues. Event contents are
untrusted data. Authentication headers and webhook secrets stay outside task
history and telemetry.

Use Codex as the push-stream reference: wait for activation, route notifications
by their subscription request ID, distinguish termination from transport loss,
and cancel streams with their owner. The WebSocket client controls subscriptions
and receives lifecycle notifications; event arrival alone does not authorize a
new model turn or an external action. Keep server discovery, tools, and event
subscriptions separate so polling and webhook delivery fit the same client
boundary. Webhook callbacks require signature verification before delivery.

Local source audit, macOS arm64, 2026-10-30:

| Source | Revision | Events implementation found |
| --- | --- | --- |
| Codex | `2681f8cba2831ef72bca2c0672b2e49d5f690745` | Yes: `codex-rs/codex-mcp/src/resource_client.rs`, `rmcp-client/src/event_notification_transport.rs`, `app-server/src/request_processors/mcp_event_stream.rs`; discovery and push streams, activation/cancellation, bounded reconnect. The inspected path is hosted-app oriented, not all draft delivery modes. |
| Local `harness/codex` | `f3875db6d943a4447be6883b352a89d232a41219` | Same event discovery/push implementation is present. The surrounding harness does not add a separate event workflow. |
| eve | `f4e8ef14ff1f799286ea983dc5fd6e96208497c5` | Yes: `packages/eve/src/runtime/connections/events/actions.ts` discovers webhook-capable events; `lifecycle-step.ts` manages subscriptions through a Connect backend; verified delivery resumes owned workflows. |
| OpenCode | `fa96f42f6cd8bf21f11fd5b38d78e2dd34d5563e` | No Events draft integration found. `packages/core/src/mcp/client.ts` handles ordinary catalog/resource changes, including modern core subscriptions. `schema/src/mcp-event.ts` describes internal status/catalog events. |
| Pi Coding Agent | `e7a0df27c09d11bf4161d3605246cbf57a129cb2` | No Events draft integration found. `packages/mcp/src/client.ts` implements generic requests/notifications and handshake-based connection setup. |
| Pi Durable | same Pi revision | No Events draft integration found in `packages/durable`; generic agent inbox/task events do not implement MCP Events. |
| DeepSeek Harness | `ce7073d51254c26cd63b22a60835b8f948deb447` | No Events draft integration found. `packages/mcp/mcp-client/src/connection.ts` supervises connections and refreshes tools/resources using the MCP SDK. |
| Zed agent | `a84689073d296dfd39987bc7dd478e43ef76d83a` | No Events draft integration found in `crates`; `context_server/src/protocol.rs` has ordinary MCP initialization and notifications. |
| T3 Code | `f054d1b8018721bd997d99cbb918a7b17bf098a4` | Generated Codex event-notification types exist under `packages/effect-codex-app-server`; no application event-subscription workflow found. It controls other harnesses. |

Reproduce in each checkout with `git rev-parse HEAD`, then
`rg -n 'events/(list|poll|stream|subscribe|unsubscribe)|notifications/events/|mcpServer/event'`
over its source and inspect the matches and MCP connection owner. For the core,
read `docs/specification/2026-07-28/basic/patterns/subscriptions.mdx`, the transport
bindings, and `server/discover.mdx`. For Events, read the pinned design sketch.
Negative findings concern these local revisions, not every released binary or
third-party extension. Source inspection is not a live interoperability test.

Tradeoff: adopting the draft meets the requested functionality before
standardization, but its methods and delivery rules may change. Verification
must cover simultaneous subscriptions, independent cancellation, disconnects,
cursor continuity, duplicate events, heartbeat/gap/termination handling, and
webhook authentication. Advertise only the implemented delivery modes.

## 2026-10-30 — Client-hosted tools

User requirement: clients can register tools implemented in their own process,
including a desktop browser. Select Codex's direct request/response bridge. A live
connection registers a bounded catalog for a task; the server sends `tools.call`
requests on that same WebSocket and accepts results only from that connection.
One connection owns the client catalog for a task. Registering an empty catalog
or disconnecting removes it. Registration does not launch a model turn.

Keep initial model tools unchanged. Append new/changed definitions through the
shared tools record (`additional_tools` for GPT), and append a developer notice
for removals, as Codex does. Refresh availability between model steps. Expose the
same functions through code mode as `tools.client__NAME`; routing always checks
the current registration. After compaction, restore the current catalog explicitly.
An already-issued call that loses its owner returns an outcome-unknown failure;
do not retry it automatically. Cancellation sends `tools.cancel` and releases the
pending call. Start with JSON arguments and Codex-style text `contentItems` plus
`success`; do not advertise image/audio results before implementing their model
representation. No client application is required for this server feature.

Source comparison on macOS arm64, 2026-10-30:

- Codex `2681f8cba2831ef72bca2c0672b2e49d5f690745`:
  `codex-rs/app-server/src/dynamic_tools.rs`, `bespoke_event_handling.rs`,
  `app-server-protocol/src/protocol/v2/item.rs`, and
  `core/src/context/world_state/top_level_tools.rs` show registered schemas,
  outbound client calls, correlated results, appended definitions, and textual
  removal notices. Paths after the first are relative to `codex-rs/`.
- OpenCode `fa96f42f6cd8bf21f11fd5b38d78e2dd34d5563e`:
  `packages/plugin-browser/src/connection.ts` uses plugin RPC attachment lifetimes,
  control events, separate command/result operations, and browser network tunnels.
  Its per-session ownership and outcome-unknown handling are useful references;
  the extra browser-specific channel is unnecessary for a generic tool bridge.

Reproduce with `git show COMMIT:PATH` in the local source checkouts. Tradeoff:
one owner per task avoids ambiguous routing; collaborative multi-owner catalogs
would need a separate namespacing/ownership design. The client tool catalog is
ephemeral; durable history records declarations and results, never live ownership.

## 2026-10-30 — WebSocket transport over IP and Unix sockets

User decision, clarified after the initial transport request: support two modes.
An embedded server runs in the same process as the future client and uses a Unix
domain socket for the API. A remote server listens on loopback and is reached
through an SSH port forward, matching Codex's remote WebSocket approach. Keep SSH
outside the agent protocol; client-side SSH management comes with the future client.
Use one HTTP/WebSocket handler and select its listener at startup. The IP binding uses Dart's
HTTP/1.1 WebSocket upgrade; HTTP/3 is not an implemented or advertised capability.
Unix sockets use the same upgrade and framing, with an explicit filesystem path,
private socket permissions, and no automatic deletion of pre-existing paths.
The CLI accepts `serve --socket PATH` and the local address `unix:///absolute/path`.
Its embedded execution mode creates a private temporary socket directory and
starts the server in-process; it does not spawn a second server process. Agent,
SQLite and network isolates remain as previously decided. Removing UDS in favor
of direct in-process communication is outside current scope.

Evidence: Dart 3.13.7 `dart:io` InternetAddressType.unix, HttpServer.bind, and
HttpClient.connectionFactory; the installed SDK's `_http/http_impl.dart` skips
TCP options for Unix sockets. The [official connectionFactory example](https://api.dart.dev/dart-io/HttpClient/connectionFactory.html)
uses Socket.startConnect with a Unix address. Verify the same task, tool-call,
cancellation, and disconnect behavior through both listeners. Unix sockets are
available on supported Unix platforms; no Windows named-pipe support is claimed.
Codex source `2681f8cba2831ef72bca2c0672b2e49d5f690745`,
`codex-rs/app-server-transport/src/transport/websocket.rs`, explicitly directs
loopback users to SSH port-forwarding and rejects browser Origin headers.
`codex-rs/app-server-daemon/README.md` describes remote lifecycle commands for
servers launched through SSH. We adopt its transport arrangement, not its daemon
updater, compression, or remote client implementation. Reproduce with
`git show COMMIT:PATH` in the Codex checkout.

## 2026-10-30 — Runtime and interoperability verification

The following evidence supersedes the implementation-pending statements recorded
earlier in this document. Reproduction procedures are in
[verification.md](verification.md); the implemented API is in [api.md](api.md).

The local suite has 23 behavior tests. It covers native provider state and ordered
updates, cancellation and incomplete responses, MCP process sharing and restart,
HTTP event activation/routing/reconnection/cursors/deduplication, polling, signed
webhooks, client-tool ownership and disconnects over loopback and UDS, compaction
failure/cancellation, bounded overflow recovery, restart, and durable history
fork/export/import. These are local protocol fixtures, distinct from live provider
verification. MCP Events interoperability with an independently deployed server
has not been measured.

Cancellation testing found that wrapping `Future.delayed` in a cancelled future
does not stop its underlying timer. Runtime delays now use the package's
`CancellableCompleter` with explicit timer cleanup. This also avoids a completion
race in version 2.0.1's synchronous delayed-future completer. Model response readers have explicit transport
ownership so cancelling an SSE read releases the request without closing the
shared HTTP pool. Transfer cancellation removes staged files before publishing;
the storage owner receives cancellation while processing a paged operation.

On macOS arm64, Dart 3.13.7, 10 logical CPUs, both JIT and the AOT bundle completed
1,000 cells with SQLite commits at approximately 100 cells/second over ten seconds.
All 100 agents completed their burst work while an additional SQLite owner's
single recursive statement was still running. These benchmark runs used WAL and
`synchronous=FULL`. Raw reports: [JIT](evidence/runtime-jit.json),
[AOT](evidence/runtime-aot.json).

| Observation | JIT | AOT |
| --- | ---: | ---: |
| Start 100 agents plus 100 writers | 377 ms | 209 ms |
| RSS increase after creating those owners | 26.5 MiB | 31.9 MiB |
| OS threads during burst work | 30 | 27 |
| Sustained cell latency, median / p99 | 1.03 / 2.26 ms | 0.91 / 2.59 ms |
| Sustained heartbeat interval p99, 10 ms target | 11.23 ms | 11.27 ms |
| Burst/startup heartbeat interval maximum | 171.2 ms | 128.2 ms |
| Observed process peak RSS before sustained phase | 426.1 MiB | 101.1 MiB |

The observed startup jitter rules out a hard realtime guarantee. The ten-second
phase is a throughput check, not a long soak or evidence under disk stalls and
swapping. AOT must be built with `dart build cli` so the SQLite and QuickJS native
assets accompany the executable; a bare executable without those assets is not a
valid measurement.

The [live GPT comparison](evidence/live-gpt-comparison.json) used `gpt-6.1-sol`,
low effort, isolated temporary workspaces, and disabled Codex skills/plugins.
Happen HTTP, Happen upstream WebSocket, and the installed Codex CLI each produced
a working CSV program. Independent checks covered the initial result, an empty
input, exact decimal arithmetic, and filtering unpaid rows. Elapsed times were
42.1, 39.4, and 41.7 seconds respectively. This single small task establishes
functional execution; it does not rank harness quality or latency.

The [live context check](evidence/live-context.json) passed over both GPT
transports. It changed low effort to high, installed a native checkpoint,
restarted the server, forked, exported/imported, and continued. The random tool
receipt was absent from the replacement context's visible text; the model called
history tools to recover it, completed the unfinished file action, and followed
the restored `AGENTS.md` instruction. Historical event identity survived transfer.

On HTTP, both the unchanged-effort and changed-effort continuations reported
6,272 cached input tokens. On WebSocket, those observations were 0 and 6,272.
Thus effort updates can coexist with cache hits, but cache behavior varied even
on the unchanged-effort request. These sequential short checks are not a
controlled cache-performance benchmark or a long-context quality evaluation.

The DeepSeek package's nine local adapter tests pass. The initial anonymous OpenCode route
from its pinned checkout returned HTTP 429 for `deepseek-v4.1-flash-free`; see the
[sanitized result](evidence/deepseek-route.json). That route's model identifier is
different from the supported native `deepseek-flash`. No silent alias or account
change was introduced. Live DeepSeek execution and an OpenCode quality comparison
remain unverified; the local tests do not substitute for them. The subsequent
Console login and authenticated route results are recorded below.

## Remaining verification limits

- Successful live Happen inference through OpenCode Console and a live tool-task
  comparison; device authorization itself now passes.
- Long tasks, repeated compactions, controlled cache comparisons, and long soaks.
- Independently deployed MCP Events servers and public webhook delivery.
- Other operating systems, hardware, disk stalls, and simultaneous blocked writers.
- A real remote SSH deployment; the loopback protocol and UDS paths are tested
  locally, while SSH forwarding itself remains client infrastructure.

## 2026-10-30 — OpenCode Console access from the DeepSeek package

User requirement: `packages/deepseek` must authenticate with OpenCode Console and
use the explicitly selected `deepseek-v4.1-flash-free` route. This extends the
earlier native-only model selection. Keep native DeepSeek API-key access available;
select the Console backend explicitly and never substitute a paid model.

The DeepSeek package owns Console device authorization, private credential
persistence, coalesced token refresh, and inference headers. Follow the pinned
OpenCode source's `opencode-cli` device client, organization-scoped authorization,
`/auth/device/code` and `/auth/device/token` endpoints, and `Authorization` plus
`x-org-id` inference headers. Use a Happen User-Agent. Each application owns its
refresh token; Happen must not rotate the CLI's credential or copy browser cookies
into task data. Errors, history, telemetry, and evidence must exclude credentials.

Source: OpenCode `fa96f42f6cd8bf21f11fd5b38d78e2dd34d5563e`,
`packages/core/src/plugin/provider/opencode.ts`, `packages/core/src/console-access.ts`,
and `packages/cli/src/commands/handlers/auth/login.ts`. Reproduce with
`git show COMMIT:PATH`. The published OpenCode 2.2.2 CLI's device flow was approved
in the user's Chrome session, and its authenticated free-model request returned
`READY`. Package authentication and inference are verified separately; CLI success
alone does not establish direct Happen access.

Tradeoff: Console's Chat Completions route has different capabilities from native
DeepSeek Messages. The provider adapter must preserve the common tool contract,
fixed effort, and durable state within the selected route's capabilities. A hosted
route rejection must be reported as such, without disguising Happen as OpenCode
or silently changing models.

Implementation uses `DeepSeekProvider.opencode` and `login --provider opencode`.
The network owner selects it through `providers.deepseek.backend: "opencode"`
and shares its HTTP pool with the other providers. The free model's 200,000-token
context and 32,000-token output cap come from the pinned OpenCode
`packages/core/src/models-dev/snapshot.txt`; these differ from the native model's
limits. The model name is never translated to a paid route. Chat has one tool
catalog per request, so it sends the latest schemas and keeps chronological
text notices for tool additions. Native Messages retains its protocol-level
ordered additions. OpenCode's `packages/ai/src/protocols/openai-chat.ts` also
serializes the request's current tool catalog.

Live evidence on macOS arm64, Dart 3.13.7:
[Console authorization and route check](evidence/deepseek-console.json).
Happen's independent device login succeeded in the selected Personal workspace.
Its authenticated request with the Happen User-Agent received HTTP 429 and
`FreeUsageLimitError`; the service reported that free models work in OpenCode and
returned a retry interval. The separately authorized OpenCode 2.2.2 CLI returned
`READY`. This establishes working authentication and different observed inference
outcomes, not the service's internal cause or a successful live Happen tool run.
No client identity substitution or paid fallback was used.

Local HTTP fixtures exercise authorization, private persistence, organization
selection, refresh coalescing, cancellation, exact route selection, request limits,
tool conversion, and sanitized hosted denials. The UDS server fixture executes a
real code cell and writes a file through the configured Console adapter. These
fixtures verify implementation behavior independently of the live access limit.
Validation: all 32 repository tests passed; the 18 focused DeepSeek tests passed
after the final adjustment. Formatting, `dart analyze`, and whitespace checks are
clean. Commands are listed in [verification.md](verification.md).

## 2026-10-30 — SQLite connection settings

User decision: every task database connection uses `journal_mode=WAL`,
`synchronous=NORMAL`, and `foreign_keys=ON`. Set them immediately after opening
the connection, before schema changes or transactions. The same `TaskStore`
constructor handles creation, reopening, fork staging, and history imports.

This replaces the previous `synchronous=FULL` setting. With WAL, NORMAL reduces
sync operations while preserving database consistency; recently committed
transactions can be lost after a power failure or operating-system crash.
Foreign-key enforcement is enabled explicitly on each connection rather than
depending on SQLite's default. See SQLite's
[synchronous](https://www.sqlite.org/pragma.html#pragma_synchronous) and
[foreign_keys](https://www.sqlite.org/pragma.html#pragma_foreign_keys) documentation.

Verification on macOS arm64, Dart 3.13.7, `sqlite3` package 3.8.0:
`dart test test/storage_test.dart` queries the effective pragmas on new and
reopened databases and verifies rejection of a delete that violates a foreign
key. Before this change it reported `wal`, `2` (FULL), `0` (foreign keys off);
the required values are `wal`, `1` (NORMAL), `1` (foreign keys on). Existing
benchmark reports retain their original FULL setting; performance and power-loss
behavior under the new settings have not been measured.

## 2026-10-31 — Global YAML configuration and live MCP reconciliation

User requirements: configure global MCP servers in `~/.happen/config.yaml`, with
local `command`/`args` entries and remote `url` entries in the same map; validate
reloads in Dart; have a running server apply file edits by starting, stopping, or
replacing shared local processes. Remote server processes remain externally owned.

Put the reusable configuration boundary in `packages/config`. It depends on Dart
libraries, not Flutter, providers, the agent loop, or MCP runtime code. It owns
path discovery, bounded YAML loading, the embedded schema, and file notifications.
`packages/server` owns applying validated snapshots in its shared network isolate.
`packages/mcp` continues to own subprocesses, client connections, subscriptions,
and the existing bounded crash/reconnection policy. Configuration is not task
history, and task cancellation does not own these shared processes.

Use `yaml` 3.1.4 and `json_schema` 5.2.2 with an embedded Draft 7 schema. The
`config-schema` CLI command exports the same Dart constant used at runtime, so
installed/AOT programs do not need a checkout or a schema-generation step.
The schema validates supported fields and types, including exactly one command
or URL, transport-specific fields, and string arguments/environment/headers.
Additional semantic checks reject normalized server-name collisions and invalid
HTTP URLs. Provider-specific settings/model limits remain provider-owned; provider
configuration and webhook `public_url` remain startup settings.

The config path is independent of the existing data directory, avoiding an
implicit credential/history migration. `--config` and the embedding API's
`configPath` override it. When YAML is missing, startup can read the old data
directory's `config.json`, applying the same validation. Files are not merged and
malformed YAML never falls back. Once YAML is selected in a running server, its
temporary deletion does not reactivate legacy settings. Missing initial config
is empty; deleting an already loaded file keeps the last configuration. An explicit
`mcp_servers: {}` removes all entries. Empty/comment-only YAML is also empty config;
an explicit null document is rejected. Config reads are limited to 1 MiB.

Watch parent directories with `dart:io`, debounce notifications for 200 ms, and
reconcile every two seconds to cover missed events and missing/recreated parents.
This handles editor rename saves without watching a retired inode. Compare direct
filenames within each watched parent because native events may resolve symlinks
such as macOS `/var` to `/private/var`. Cancellation closes streams and timers and
cancels an active read. The network owner serializes automatic and manual reloads,
coalesces changes, and cancels superseded automatic work. An interrupted apply
forces subsequent reconciliation even when the file reverts to its previous value.

Validate the complete candidate before touching processes. Canonical mapping
order makes comments and key reordering harmless to running connections. Added
commands launch once per harness; changed process settings replace that process;
removed/disabled entries close their subscriptions and stop their processes.
Unchanged entries retain their PIDs and subscriptions. URL changes replace client
connections without launching or shutting down remote servers. Shutdown waits for
in-flight reconciliation, then closes connections and reaps local processes.

Connected clients receive `mcp.config.reloaded` with server statuses or
`mcp.config.error` with a sanitized diagnostic. Repeated unchanged errors are
suppressed. YAML parser source excerpts and validator instance values are never
included, since environment/header values may contain credentials. Neither event
contains the configuration snapshot. `mcp.reload` remains an immediate manual
reload through the same validation/apply path.

Evidence and reproduction, macOS arm64, Dart 3.13.7:

- Inspected [yaml documentation](https://pub.dev/packages/yaml),
  [json_schema documentation](https://pub.dev/packages/json_schema), and their
  resolved Dart sources, including YAML duplicate/recursive-alias handling and
  schema validation diagnostics. Also inspected `cancellation_token` 2.0.1's
  completer cleanup behavior. Versions and checksums are in `pubspec.lock`.
- Consulted Codex `2681f8cba2831ef72bca2c0672b2e49d5f690745`,
  `codex-rs/config/src/mcp_types.rs`, especially `McpServerTransportConfig`, with
  `git show COMMIT:PATH`. Happen retains its implemented field names such as
  `inherit_env` and `header_env`; this does not advertise Codex's OAuth/helper or
  approval options. MCP wire protocols are unchanged by this config boundary.
- Before the fix, the reload regression changed `args` to `[42]` and received a
  reconnecting replacement with no PID: the healthy process had been stopped.
  After validation was moved ahead of reconciliation, the request is rejected
  with the field path and the original process remains callable.
- `dart test test/config_test.dart test/config_reload_test.dart test/mcp_test.dart`
  passes all nine focused tests. Real YAML writes and atomic replacements cover
  adding processes, changing the executable, disabling/removing entries, retained
  subscriptions, missing files, rapid edit/revert during discovery, and shutdown.
  Tests inspect actual process identities and verify retired PIDs have exited.
  A mixed command/HTTP fixture changes the remote URL and removes the connection,
  then verifies that the remote server still serves requests. Existing MCP tests
  cover crash supervision and independent request cancellation.
- `dart run bin/agent.dart --help` and `dart run bin/agent.dart config-schema`
  verify CLI discovery and schema export. The full verification commands remain
  in [verification.md](verification.md).
- The full `dart test -r expanded` run passes all 40 tests; `dart analyze`
  reports no issues. Formatting and `git diff --check` are clean.

Tradeoffs and limits: polling adds small recurring file I/O and reload latency is
not a realtime guarantee. Validation protects against malformed configuration;
a well-formed command or URL can still be unavailable, and changing to it does
not roll back a failed process launch or connection. A valid partial edit cannot
be distinguished from an intentional complete config; use atomic saves for
multi-step programmatic writes. The lifecycle evidence is from local subprocess
and HTTP fixtures on macOS, not a new independently deployed MCP interoperability
test or verification on other operating systems.

## 2026-10-31 — Desktop tool detail state

Give the Code & output expansion tile and its selectable text distinct, stable
`PageStorageKey`s beneath the existing tool-ID key. Expansion state is a boolean;
the selectable text's internal scroll position is a double. Sharing a storage
identifier makes the first expansion fail in `ScrollPosition.restoreScrollOffset`
with `type 'bool' is not a subtype of type 'double?'`, followed by the reported
`_InactiveElements.remove` assertion when Flutter rebuilds the failed subtree.
The unkeyed inner tile also shared its parent's expansion state.

Evidence: the desktop widget regression fails before the repair and passes after
it. It opens details during a running call, receives nested tool results, closes
and reopens the parent with details collapsed, and opens nested output. Existing
session tests do not render widgets. Inspected the installed Flutter 3.47.8 source
at `737ba8f885`: `widgets/page_storage.dart`, `widgets/expansible.dart`,
`widgets/scroll_position.dart`, and `material/selectable_text.dart` under
`packages/flutter/lib/src`. PageStorage derives identifiers from the ancestor
PageStorageKey path; the text scroller and expansion controller otherwise use the
same path.

Reproduction and verification on macOS arm64, Dart 3.13.7, Flutter 3.47.8:

    cd packages/desktop
    flutter test test/app_test.dart --no-pub --reporter expanded
    flutter test --no-pub --reporter expanded

From the repository root, `dart analyze packages/desktop` reports no issues. The
desktop suite passes all three tests, and the running app accepts hot reload.
Opening live tool details after reload renders selectable output with zero error
widgets and no reported runtime errors. The keys are scoped by each tool's
existing key and preserve independent expansion state and text scroll offsets.
Verification on other operating systems remains unmeasured.

The broader `dart test --reporter expanded` check in the current working tree
passes 38 tests and fails `test/compaction_test.dart` and `test/server_test.dart`
with `Task is busy`; a focused rerun reproduces both failures. Those tests import
the server, not the desktop UI. Whole-repository `dart analyze` also reports one
`use_null_aware_elements` informational lint in `packages/server/lib/src/network.dart`.

## 2026-10-31 — Append-only MCP tool updates in existing tasks

User requirement: changing global config must make newly configured server tools
available to an existing GPT task at its next model request, whether the task is
running or idle. Keep the task's original top-level tool list and instructions
fixed. Append shared `tools` records for new or changed MCP definitions, encoded
as developer-role `additional_tools` by the existing GPT adapter. Commit the
declarations, availability notice, and MCP snapshot together. Unchanged tools
are not redeclared; removals append a notice and routing checks the live registry.
Config changes alone do not start a model turn.

Expose direct calls with the pinned Codex namespace convention
`mcp__SERVER.TOOL`. Preserve existing code-mode names
`tools.mcp__SERVER__TOOL`. The shared network owner routes both to the same
supervised MCP connection, with caller cancellation and no automatic call retry.
Catalog entries retain their existing flattened `name` and add `namespace` and
`tool_name`, avoiding ambiguous splitting when names contain double underscores.
Compaction replaces earlier harness MCP declarations/notices with the current
catalog; all original updates remain in durable history.

Refresh at each model-step boundary and before manual compaction. Reconcile the
config through the network owner's serialized reload path before returning the
catalog, since a tool can write the config and finish before the file watcher's
200 ms debounce. Invalid/missing edits retain the running catalog and its existing
sanitized config diagnostic. This adds a bounded config read per model step;
unchanged settings do not reconnect processes. File notifications still update
shared processes while tasks are idle. Connecting or changing credentials remains
separate from declaring tools.

Sources inspected on macOS arm64, Dart 3.13.7:

- Codex `2681f8cba2831ef72bca2c0672b2e49d5f690745`,
  `codex-rs/core/src/context/world_state/top_level_tools.rs` appends changed
  declarations and textual removals; `codex-rs/codex-mcp/src/tools.rs` and
  `codex-rs/core/src/tools/handlers/mcp.rs` establish canonical namespace/member
  identities and MCP function declarations. Reproduce with `git show COMMIT:PATH`
  in the pinned Codex checkout.
- The [OpenAI prompt-caching guide](https://developers.openai.com/api/docs/guides/prompt-caching#manage-tools-with-append-only-updates)
  documents preserving tool-loading history with `additional_tools`. Its
  [input-item schema](https://developers.openai.com/api/reference/resources/conversations/methods/create)
  specifies developer role and a tools list. Read 2026-10-31.

Verification:

- `dart test test/server_tools_test.dart` failed before the repair because the
  model's next request contained no `additional_tools` declaration. It now passes
  using real config writes and a supervised stdio process. It covers an edit
  performed by the running task, a changed schema/description between turns,
  append-only input prefixes, unchanged initial tools, declaration deduplication,
  invalid config, direct and code-mode execution, removal, and restoration after
  compaction/restart. It waits for the separate startup maintenance sweep before
  testing restart continuation.
- `dart test test/server_tools_test.dart test/gpt_test.dart test/deepseek_test.dart test/mcp_test.dart -r expanded`
  passes all 15 focused tests. Analysis of the changed server/agent/MCP files,
  regression and verification script reports no issues; `git diff --check`
  passes. No Dart formatter was run.
- The final full `dart test -r expanded` run in the concurrently edited checkout
  passed 42 tests and failed the separate archive/restore case in
  `test/server_test.dart`: its restored turn returned `turn.failed` instead of
  `turn.completed`. This case exercises the concurrent maintenance/archive
  changes. Whole-repository `dart analyze` reported one informational unnecessary
  import in the concurrently added `packages/desktop/test/view_test.dart`.
- `dart run tool/verify_mcp_tools.dart` passes against live `gpt-6.1-sol`, low
  effort, over HTTP/SSE and WebSocket with a private UDS client. Both tasks began
  without MCPs, then loaded the actual `dart mcp-server --disable analysis` and a
  local probe from config. GPT called the new namespaced probe directly and
  returned its supervised PID. Sanitized measurements and checks are in
  [mcp-tools-live.json](evidence/mcp-tools-live.json). Elapsed times were 9.2 s and
  10.3 s, including the initial turn and server discovery; these are single-run
  functional observations, not latency or cache benchmarks.

This evidence was collected from the uncommitted working tree based on Happen
`3229e0fc5909b0686f805632b236247dff674146`.

Limits: the live run verifies one GPT model and current Dart MCP discovery, plus
execution of the independent probe. It does not verify every Dart tool or new
live DeepSeek behavior. Existing DeepSeek adapters consume the same shared tool
records through their native ordered-addition or Chat catalog paths; their local
adapter tests pass. Other operating systems and repeated live compactions remain
unmeasured for this change.

## 2026-10-31 — Tool changes while the server is stopped

User requirement: stop the server, edit global config, restart it, and resume an
existing task with the new tools. The task may have had no MCPs previously, and
shutdown may interrupt an active turn.

Use the same durable-snapshot comparison as live updates. A fresh network owner
discovers the current validated config; the resumed agent reads `mcp_snapshot`
from task storage and appends any differences before requesting a model response.
This does not depend on a file-watcher notification from the previous server or
change the frozen initial tool prefix. New and changed definitions use the
existing `additional_tools` encoding; removals append availability notices and
the current registry rejects stale calls. No further provider or storage format
change was needed.

Extended the existing server-level test instead of introducing a second fixture
or a new runtime hook. It closes the embedded server and its owners before each
config edit, creates a fresh server, and immediately resumes the same task IDs.
It checks changed definitions, removal, a completely new server, preserved input
prefixes, and successful calls against actual supervised subprocess PIDs. The
task with no prior MCPs is stopped with an HTTP/SSE model response in flight and
resumed first after adding the new MCP offline. The earlier explicit wait for
startup maintenance was removed; task admission now uses the current server's
ordinary lifecycle. Compaction and unchanged-catalog restart remain covered.

Verification on macOS arm64, Dart 3.13.7:

- `dart test test/server_tools_test.dart test/config_reload_test.dart test/compaction_test.dart test/server_test.dart -r expanded`
  passed all nine focused tests before adding the in-flight shutdown case.
- The final `dart test -r expanded` run, including that case, passed all 44 tests
  in the current working tree.
- `dart analyze test/server_tools_test.dart packages/agent packages/server packages/mcp`
  reports no issues; `git diff --check` passes. No Dart formatter was run.

The restart evidence uses the local GPT protocol fixture and fresh embedded
server/network/storage owners. Live GPT acceptance of the same tool-update wire
format is established by the preceding entry; that live run did not restart the
server between config edits. Abrupt process termination and other operating
systems were not measured in this follow-up.

## 2026-10-31 — Desktop syntax highlighting and immutable snippets

Use pure Dart parsing for desktop code-mode source, with JavaScript selected
explicitly for `functions.exec` and legacy unnamespaced `exec`. Keep one
`SelectableText.rich` for source and output so copying preserves their exact
text. The output is plain text. Conversation source is immutable once received;
cache derived spans by `(language, source)`, independently of transient tool
objects and row lifetimes. Bound the LRU to 128 entries and 256 Ki UTF-16 source
units. No tokenization happens on a cache hit.

The reusable `highlightedCode` function supports all bundled languages and their
aliases, including diff/patch. Use `val_highlight` 0.1.1 for its 57 grammar
definitions (including generic/plain text); initialize `re_highlight` 0.0.3's
194-language registry only when the requested language is absent from the fast
registry. Do not auto-detect languages. Both engines are Dart implementations;
the harness client's `shiki_flutter` 1.1.0 also defaults to pure Dart, but its
TextMate/Oniguruma pipeline was substantially slower in this local comparison.
This selects a faster scanner plus broader fallback rather than claiming VS Code
token/theme fidelity.

Resolve the fast scanner's interned scope stacks once, build flat spans from
contiguous original-source ranges, and coalesce adjacent equal styles. The
fallback renderer also builds flat spans, avoiding the dependency renderer's
repeated copying of parent child lists. Resolve dotted scopes and inherited
styles against the same GitHub light palette. Fast parsing is limited to 128 Ki
source units; the regex fallback is limited to 16 Ki and 2,000 units per line.
Larger, unsupported, or failed parses remain selectable verbatim. These are work
bounds, not a hard CPU-time guarantee. A future diff viewer can use the same
language API; a virtualized diff viewer is not implemented by this change.

Evidence on macOS arm64 (Apple M1 Pro), Dart 3.13.7, Flutter 3.47.8, JIT:
[measurements](evidence/desktop-highlighting.json) and
[comparison source](evidence/desktop-highlight-comparison.dart.txt). The committed
desktop benchmark uses 100 warm-up misses, 21 distinct-source samples per size,
and 10,000 repeated cache hits. Warm uncached JavaScript parse/span construction
medians were 0.327 ms for 1,010 units, 2.375 ms for 32,320, and 6.197 ms for
101,000. Cached calls averaged under 1 us. Initial registry/JavaScript parse/render
took 37.445 ms. A separate five-sample comparison at 32,320 units measured
2.301 ms for this implementation, 195.179 ms for the stock `re_highlight`
renderer, and 3,996.052 ms for Shiki with its pure Dart engine and token cache
disabled for these inputs. These are synthetic repeated snippets and exclude
Flutter layout/paint; they do not establish AOT performance or exhaustive
language-quality equivalence.

Source inspection: the pinned packages' highlighter, grammar compiler, scope
table, JavaScript/diff grammars, token buffer, and renderer implementations, plus
[val_highlight](https://pub.dev/packages/val_highlight),
[re_highlight](https://pub.dev/packages/re_highlight), and
[Shiki](https://pub.dev/packages/shiki_flutter) package documentation. Resolved
versions and archive checksums are in `pubspec.lock`. The fast scanner compiles
states lazily and caches compiled grammars; its result stores contiguous token
ranges in integer buffers. Keeping the second parser costs an extra dependency
and a cold initialization for less common languages. The new fast package's
long-term maintenance and full-corpus fidelity remain unmeasured.

Reproduce the desktop checks and benchmark:

    cd packages/desktop
    flutter analyze lib/app.dart lib/code_highlight.dart test/app_test.dart test/code_highlight_test.dart tool/bench_code_highlight.dart --no-pub
    flutter test --no-pub --reporter expanded
    flutter test tool/bench_code_highlight.dart --no-pub --reporter expanded

To reproduce the comparison without adding Shiki to the application, create a
temporary Flutter package with `flutter` and `flutter_test` SDK dependencies and
`val_highlight: 0.1.1`, `re_highlight: 0.0.3`, `shiki_flutter: 1.1.0`. Copy
`packages/desktop/lib/code_highlight.dart` into its `lib/` and the comparison
source above into `test/comparison_test.dart`, then run `flutter pub get` and
`flutter test test/comparison_test.dart --no-pub --reporter expanded`. Remove the
temporary package afterwards.

The focused checks protect JavaScript keyword/function colors, source/output
selection text, expansion and task switching, aliases, embedded HTML/JavaScript,
diffs, a fallback-only language, incomplete syntax, Unicode/CRLF, and plain-text
fallbacks. All eight desktop tests pass, scoped analysis and whitespace checks
pass. Hot reload succeeded in the running Happen application; VM inspection
confirmed the new library/function is loaded, and no runtime errors were
reported. The running route and task state were preserved. Other operating
systems, production AOT timings, and real large-file rendering remain unmeasured.

## 2026-10-31 — Thin desktop, accounts, and message delivery

The user requested a minimal Flutter desktop that embeds the Dart server, uses
UDS WebSockets, and preserves its running state during UI development. Root
`moon run dev` launches `packages/desktop` with Flutter hot reload. Server,
connection, and desktop database ownership begin in `initState` and end through
coordinated close. Native menu/file-picker registrations require rebuilding the
macOS runner. This follows the development objective in the user's
[language article](https://adelnz.com/writing/a-self-modifying-ai-agent-part-one-choosing-a-language/);
it does not promise that initialization or suspended async bodies are rerun by
hot reload.

The desktop's SQLite isolate owns UI settings, checkout identities, and task
references. Task transcripts remain in the server's per-task stores. Stable
checkout keys retain tasks through remote addition/removal/replacement; the
current logical identity is a normalized Git remote or absolute local path.
Authentication is stripped from remote identities. Multiple-server and SSH
management is deferred, without binding task ownership to a mutable remote URL.

Use the Harness client's `macos_file_picker` for folder selection. Settings is
available through the gear and the native Command+, menu. Provider selection
and Steer/Queue are app settings; composer controls contain model and reasoning.
Enter sends and Shift+Enter explicitly replaces the current selection with a
newline. Nested host-tool activity stays beneath its code-mode parent.

Expose OpenCode as provider `opencode` independently of native DeepSeek. The old
`deepseek` configuration with `backend: opencode` still routes existing tasks;
its catalog entry declares `alias_for: opencode` so the desktop presents one
account choice. OpenCode uses the already implemented exact free-model adapter,
shared HTTP pool, and private Console login. No new model capabilities or paid
fallback are advertised. Native DeepSeek remains an API-key option. Catalog
status reveals no credential values.

Each browser account has Sign in, Sign out, and Switch account controls. A
successful login refreshes status, shows confirmation, and activates Happen's
window. Sign-out cancels and awaits shared login/refresh work before deleting
Happen's login or Codex reference; it does not delete another application's
credentials. The GPT callback flushes its browser response before releasing the
authorization code. Console device authorization still follows OpenCode
`fa96f42f6cd8bf21f11fd5b38d78e2dd34d5563e`, as recorded above.

Steer appends input at the next model boundary; Queue starts subsequent turns in
order. Admission is bounded to 32 pending messages and 512 KiB per task. Pending
messages are memory-only until committed; cancellation/archive/failure discards
the remainder. Persist the chosen UI behavior. Existing model/provider and
reasoning-update contracts are unchanged.

## 2026-10-31 — Recoverable archive and long-running server ownership

User requirements: archive from the sidebar, list archives only in Settings,
restore them later, run disk maintenance daily, and design for weeks of uptime.
For retention the user explicitly chose Codex's behavior. Inspected Codex
`a795f961be68383738e56ac396742b3e8451696a`,
`codex-rs/thread-store/src/local/archive_thread.rs`, `unarchive_thread.rs`, and
`codex-rs/app-server/src/request_processors/thread_processor.rs` using
`git show COMMIT:PATH`: archive retains rollouts and supports restoration.

Happen records archive/unarchive events and metadata atomically. Archive stops
active work, discards pending input, releases client tools, and leaves history
readable. Restore permits new turns. Desktop schema version 3 projects archive
state into its sidebar references; only active tasks appear in that sidebar.
Settings lists archived titles and projects with view/restore actions.

Release idle task objects, agent isolates, and SQLite writers after work instead
of retaining every visited task. Startup, daily, and explicit maintenance share
one cancellable sweep. It processes stores sequentially, checkpoints archived
WALs without waiting on another connection, and removes abandoned staging
directories older than 24 hours when no history transfer is running. It skips
symlinks, active tasks, and unrelated directory names. It never expires canonical
history or deletes project files. Shutdown cancels maintenance and active work,
waits for owned requests, and closes the shared network/MCP owner. WebSocket
heartbeats and per-client request limits bound abandoned connection/request work.

Two regressions informed admission ordering. Startup maintenance formerly
returned `Task is busy` to an immediate resume; requests now wait for that task's
background maintenance to finish. Immediate archive could cancel the first turn
before configuration was saved, leaving restoration with `Expected a JSON object`.
The server now commits initial task configuration before the agent can be
cancelled. The existing server archive test failed before and passes after this
repair; it also exercises twelve completed tasks with zero retained task owners,
history retention, restoration, and safe staging cleanup.

The archive toast explicitly uses `persist: false`, a three-second duration, and
replaces old notifications. Flutter 3.47.8 at `737ba8f885` defaults SnackBar
persistence to true when an action exists (`material/snack_bar.dart`). The widget
regression reproduced the lingering Undo toast after four seconds, then passed
with explicit expiry. Permanent Restore remains available in Settings.

Verification environment: macOS arm64, Dart 3.13.7, Flutter 3.47.8. Reproduction:
`dart test -r expanded`, `flutter test --no-pub packages/desktop/test -r expanded`,
`dart analyze`, `git diff --check`, and root `moon run dev`. Fixtures cover
UDS execution on the new and legacy OpenCode routes, sanitized hosted denials,
sign-out during refresh, browser login cancellation/denial, archive persistence,
keyboard behavior, and archive visibility/restore/expiry. The app was rebuilt,
hot reloaded, inspected, and reported no runtime errors. Local automated menu
clicking was unavailable because macOS denied assistive access; native menu
wiring was compiled, and Settings was verified through the running Flutter UI.

These are lifecycle regressions and live desktop checks, not a multi-week soak
or a claim about crash/power-loss durability. Archived transcript storage still
grows with retained history. New live OpenCode inference was not retried; the
earlier hosted-limit evidence still applies. Custom desktop styling is deferred
to [issue #2](https://github.com/meoyawn/happen/issues/2), as requested by the user.

## 2026-10-31 — Desktop conversation rendering and durable timing

User requirement: make the native desktop transcript a conversation, with user
messages on the right, rendered Markdown answers, collapsible tools, images,
message times, and elapsed turn times. Use the existing Flutter client; keep
execution and history behind the server. The harness client is the closer
reference than OpenCode's Solid/WebView presentation. This adds conversation
behavior and uses the existing visual theme; it does not introduce a design system.

Separate the transcript from account/sidebar/composer code. Give visible rows
stable event-derived identities. Render user messages in compact bubbles and
assistant text across the reading column. Tools and visible reasoning summaries
start collapsed; nested call and Code & output state retain distinct storage
identifiers. Never render opaque provider replay state. Preserve the existing
bounded syntax highlighter and exact source/output copying.

Use `flutter_markdown_plus` 1.0.12 with `markdown` 7.3.1 for GitHub-flavored
Markdown, selectable prose, headings, lists, tables, links and inline formatting.
Custom fenced-code blocks provide explicit-language highlighting, copying and
line wrapping. Wide tables and code scroll horizontally. Unchanged Markdown
retains its parsed widget state during other rows' updates. This avoids importing
the harness client's much larger annotation/browser/diagram integration.

Markdown raster images support HTTP(S), data URLs, absolute local files, and
project-relative paths. Image previews support zoom and show readable fallbacks
for invalid or missing content. Decode inline images only below a 24 MiB encoded
source bound. Recognize MCP image content in tool result envelopes when their
disclosure opens; preserve raw results separately. This is display support, not
image attachment submission or a change to provider image-input capabilities.
HTML execution, SVG, math, and Mermaid rendering are not implemented here.

Auto-follow new output only while the reader follows the end. Manual scrolling
or opening a disclosure pauses following; Jump to latest resumes it. Late image
layout and lazy row measurements can update the bottom position. A small owned
timer updates only the running-turn label and is cancelled when that row leaves.

Display recorded message timestamps in the machine's local timezone, with an
exact timestamp/timezone tooltip. Derive completed, stopped and failed turn
durations, and tool durations, from durable start/terminal event timestamps.
Missing historical times stay unknown. Wall-clock changes can affect these
durations; they are not a separate monotonic performance measurement.

Add server-owned pending `created_at` and committed `data.sent_at` timestamps.
Direct inputs record receipt time too. Queue/steer commitment preserves the
original receipt time, rather than replacing it with processing time. These
fields remain outside the model-facing item and do not change provider prompts
or storage schemas. Older inputs fall back to event `created_at`; their original
queue receipt time cannot be reconstructed. Pending input remains ephemeral
until committed, as previously specified.

Source inspection on macOS arm64, Dart 3.13.7, Flutter 3.47.8:

- Harness `6b595ec8a160d7d0c0b5dae0a7352793944fe1d5`,
  `client/lib/ui/conversation_transcript.dart` and `conversation_markdown.dart`:
  separate user/assistant layout, lazy keyed rows, activity disclosures and
  Markdown/image presentation.
- OpenCode `958f965d35ed44d32b018fd55b02a5357a7748fd`,
  `packages/session-ui/src/components/markdown.tsx`: dedicated Markdown, image
  preview, code and streaming projection. Its web runtime is not introduced.
- Pinned Codex `f3875db6d943a4447be6883b352a89d232a41219`,
  `codex-rs/app-server-protocol/src/protocol/v2/thread.rs`: optional item and
  turn start/completion timestamps. Inspected with `git show COMMIT:PATH`.
  Happen retains its own ISO 8601 event API rather than claiming wire parity.
- [Markdown renderer documentation](https://pub.dev/packages/flutter_markdown_plus)
  and resolved `src/widget.dart`, `src/builder.dart`, `src/style_sheet.dart`:
  parsing updates, custom builders, selection, intrinsic-width table scrolling,
  and image callbacks. Resolved versions and checksums are in `pubspec.lock`.

Verification: the queued-message regression first failed with two missing
timestamps. It now checks receipt-time preservation after processing and after
server/desktop restart through the real UDS session. Widget checks cover rendered
Markdown, bubble placement, timestamps/durations, exact copying, expandable tool
state, data/file/MCP image decoding and preview, unavailable images, lazy scrolling,
and incomplete streamed code/tables at a 420-pixel viewport. The running native
app accepted hot reload, was inspected visually, and reported no runtime errors.

Reproduce from the repository root (no Dart formatter):

    cd packages/desktop
    flutter test --no-pub --reporter expanded
    cd ../..
    dart test --reporter expanded
    dart analyze packages/desktop packages/server/lib/server.dart packages/agent/lib/agent.dart
    git diff --check

Other operating systems, very large live transcripts, external image-host
availability, and production AOT rendering performance remain unmeasured.

## 2026-10-31 — macOS native asset identity across rebuilds

Normalize the generated macOS `NativeAssetsManifest.json` framework paths to
their `@rpath/` install names after Flutter assembles `App.framework`, before
embedding and signing it. Keep bundled SQLite 3.8.0, the existing schemas, and
the dedicated database owner isolates. This is a build-output repair; it does
not require an SDK patch or switching to the operating system's SQLite.

The supplied crash has two mappings of the same SQLite framework UUID
`7AF7D0CE-4BEF-36D8-B6BE-769720DD0611`, with `pc=0`, `x8=0`, and a return address
at `sqlite3_bind_int64 + 68`. Disassembling the matching bundled binary shows
`blr x8` at +64, calling the copy's mutex-enter function. Its null value is
consistent with a second SQLite copy whose global state was never initialized,
receiving a statement from the initialized copy.

The installed Flutter 3.47.8 (`737ba8f885`, Dart 3.13.7) records
`sqlite3.framework/sqlite3` but stamps the binary with
`@rpath/sqlite3.framework/sqlite3`. Replacing the file during a rebuild changes
its inode. A later lazy native binding can then load another copy because the
lookup name does not match the first copy's install name. The same mismatch
also affects the bundled QuickJS/code-mode framework.

Sources inspected: the installed SDK's
`packages/flutter_tools/lib/src/isolated/native_assets/macos/native_assets.dart`
and `native_assets_host.dart`, sqlite3 3.8.0's generated FFI bindings and hook
documentation, [Flutter issue #190799](https://github.com/flutter/flutter/issues/190799),
and the upstream fix at
[`295e9f1e553f2e946d6e24f3bf28ca33fc78a83d`](https://github.com/flutter/flutter/commit/295e9f1e553f2e946d6e24f3bf28ca33fc78a83d).
The local normalizer follows that fix for macOS bundled framework entries and
is a no-op when the SDK already emits the corrected names. It leaves system,
absolute tester, executable/process, and other-platform entries alone. Its
script is an explicit Xcode build input so editing it reruns the assembly step.

Verification on macOS 26.4, Apple M1 Pro, arm64:

- The retained native-loader probe uses the actual built manifest and SQLite
  binary in an isolated temporary framework tree. It opens a database and
  prepares a statement, replaces `Versions/A/sqlite3` with identical bytes at a
  new inode, then resolves unused integer/text bindings. The original generated
  manifest reproducibly fails with two mappings. The corrected debug and
  universal release bundles retain one mapping, bind 42 and `after-rebuild`,
  and return those exact values from the pre-replacement statement.
- All 12 desktop tests pass; scoped analysis and whitespace checks pass. The
  release bundle passes `codesign --verify --deep --strict`. No Dart formatter
  was run.
- Relaunched Happen with the corrected debug bundle. While it stayed running,
  another debug build replaced the SQLite binary (inode 99305522 to 99309702).
  The existing desktop database owner then completed `task.archive` for a
  deliberately nonexistent task ID, exercising integer binding without changing
  a user task. `vmmap` still showed one SQLite `__TEXT` mapping at the original
  address. Hot reload succeeded and no runtime errors were reported.

Reproduce from `packages/desktop`:

    flutter build macos --debug --no-pub
    dart --disable-dart-dev tool/verify_native_assets.dart
    flutter build macos --release --no-pub
    dart --disable-dart-dev tool/verify_native_assets.dart build/macos/Build/Products/Release/Happen.app
    codesign --verify --deep --strict build/macos/Build/Products/Release/Happen.app
    flutter test --no-pub --reporter expanded
    dart analyze .

Tradeoff: one small platform-specific build step remains until the selected
Flutter SDK contains the upstream fix. A full process relaunch is required once;
hot reload cannot repair native mappings already created with the old manifest.
The report's exact preceding rebuild sequence was not recorded. The loader
mechanism and live rebuild were reproduced locally; x86_64 execution, other
operating systems, notarized distribution, and long-running soaks were not tested.
