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

## 2026-10-31 — File autocomplete and overlapping WebSocket work

User requirements: `@` file autocomplete backed by the server for both new and
existing desktop tasks; keep it simple and usable over mobile networks while
100 other tasks stream on the same connection.

Add `files.search` to the existing WebSocket. It takes an absolute server working
directory, a query and optional limit; it needs neither a task ID nor a model
request. Return relative file/directory paths; directories end in `/`. Selection inserts `@path` or
`@"path with spaces"` as ordinary prompt text, without reading file contents or
changing the attachment/provider contract. See [api.md](api.md) for wire fields
and limits.

Use Git's tracked/untracked filename listing with standard untracked exclusions.
Git is optional: plain folders fall back to an asynchronous `dart:io` walk that
prunes common generated/VCS directories and does not follow directory symlinks.
No required ripgrep binary, watcher, persistent index or client checkout mirror.
Cache at most four path lists, reusing each for ten seconds; cap scans at
100,000 paths/entries and 8 MiB. Rank filenames, prefixes and substrings before
subsequences; return 20 matches by default, at most 50 and 32 KiB of paths.
Derive Git parent directories from indexed files, preserving untracked exclusion
rules without another filesystem walk. Empty Git directories or directories
containing only ignored files are therefore absent; the plain-folder walk does
include empty directories. Exact basenames and paths take priority over
descendants, following Harness's mention ranking: `@desktop` puts
`packages/desktop/` before `desktop-guide.md`. Directory selection inserts the
trailing slash and the composer uses folder icons. Async metadata checks exclude
deleted paths and recognize submodule directories. Filesystem
calls are asynchronous; CPU-only index processing and matching yield every 1,024
entries so task streams and unrelated RPCs can progress.

Each connection owns its latest search. Supersession, `files.cancel`, disconnect
and shutdown cancel its token and terminate/reap an owned Git process or cancel
the directory subscription. Search has a five-second server deadline; the client
allows ten seconds including network time. Cancellation releases the pending
client reply immediately without stopping tasks or another connection's search.
The composer debounces for 200 ms, caches 20 exact queries for ten seconds, and
rejects results for an obsolete token, caret, project or widget. It supports
Arrow keys, Enter/Tab, pointer selection, Escape, quoting, IME composition and
replacement within a draft. It saves programmatic insertions in the draft too.

The user additionally required Harness's stable autocomplete layout. The initial
inline suggestion column resized the conversation viewport as results changed.
Use the same `OverlayPortal` and composited target/follower structure as Harness,
anchored to the whole composer: bottom-left of the menu follows top-left of the
composer with a 13 px horizontal inset and 4 px gap. The menu width is the
composer width minus 26 px; it scrolls within a 320 px maximum height. Showing,
changing and hiding it never contributes height to the composer or transcript.
Overlay visibility changes after the frame, and the overlay shares the text
field's tap region so pointer selection keeps editor focus. There is no size
animation or reserved suggestion area in the conversation layout.

The existing dispatcher already permits overlapping requests and correlates
replies by ID. Its 32 pending RPC limit does not count running task streams:
start/send acknowledge admission before completion. Delayed-acknowledgement
testing exposed a separate defect: the server disconnected after exhausting
256 event credits, preventing a file search on that connection from finishing.
Keep the acknowledgement wire contract, but queue notifications in order while
credits are unavailable. Bound that queue to 1,024 events and 2 MiB;
acknowledgements drain it and RPC replies bypass it. An indefinitely stalled
consumer still disconnects at the bound and can retrieve durable history.

Sources inspected and pinned for this decision:

- OpenCode `958f965d35ed44d32b018fd55b02a5357a7748fd`,
  `packages/core/src/filesystem/search.ts` and
  `packages/tui/src/component/prompt/autocomplete.tsx`: location-owned filename
  indexes, ten-second refresh, bounded replies and in-composer selection.
- Codex `a795f961be68383738e56ac396742b3e8451696a`,
  `codex-rs/app-server/src/fuzzy_file_search.rs`,
  `codex-rs/file-search/src/lib.rs`, and
  `codex-rs/tui/src/bottom_pane/chat_composer.rs`: cancellable bounded search,
  ignore-aware enumeration and caret-aware replacement. Its
  `codex-rs/app-server-transport/src/transport/websocket.rs` also retains a bounded
  outbound channel with headroom for ordinary output bursts. Happen does not
  claim its search-session, image mention or full ranking behavior.
- Harness `6b595ec8a160d7d0c0b5dae0a7352793944fe1d5`,
  `client/lib/services/completion_catalog.dart` and
  `client/lib/ui/completion_ranking.dart`: distinguish folders from files, preserve
  the directory slash on insertion, and prioritize exact paths/basenames over
  descendants. `client/lib/ui/chat_view.dart`, `_composer`, `_updateSlashOverlay`
  and `_slashMenu`, provide the overlay anchor, width, visibility and scrolling
  behavior used here. Its Codex checkout `f3875db6d943a4447be6883b352a89d232a41219`,
  `codex-rs/file-search/src/lib.rs`, indexes directories and scores with Nucleo.
  Happen keeps its small bounded matcher; it does not claim Nucleo scoring parity.
- [Git's ls-files reference](https://git-scm.com/docs/git-ls-files) for NUL-delimited
  names and `--cached --others --exclude-standard`. The fallback walk does not
  implement `.gitignore` or `.ignore` parsing itself.

Reproduce source inspection with `git show REVISION:PATH` in the local checkouts.
Verification environment: macOS arm64, Apple M1 Pro, Dart 3.13.7, Flutter 3.47.8
(`737ba8f885`). Commands:

    dart test test/file_search_test.dart test/server_test.dart -r expanded
    flutter test --no-pub packages/desktop/test/view_test.dart -r expanded
    dart test -r expanded
    flutter test --no-pub packages/desktop/test -r expanded
    dart analyze
    git diff --check

The full server suite passed 46 tests and the desktop suite passed 16. The
100-task fixture uses real server, network, agent and SQLite owners and real
HTTP/SSE provider streams. It searches and pings before those streams end,
withholds acknowledgements on another subscribed socket, receives a search
reply with the event window exhausted, then checks 300 deltas' per-task ordering
after acknowledging. Further unacknowledged output verifies bounded disconnect.
Before the queue repair the delayed-acknowledgement case failed with
`1008 Event backlog exceeded`; afterwards it passes. UDS coverage delivers
out-of-order RPC replies, cancels one search, and delivers its obsolete reply
after a newer result. Widget tests cover new/existing drafts, keyboard/tap
selection, debounce, late replies, IME/email input, retries and lifecycle cleanup.
Analysis and whitespace checks pass; no Dart formatter was run.

After the directory and overlay follow-ups, the complete suites passed 62 server
tests and 24 desktop tests. The layout regression first failed with the inline
menu: loading alone reduced the transcript viewport's bottom edge from 736 to
704 logical pixels. With the overlay it preserves the exact editor rectangle,
transcript viewport and a nonzero reading scroll position through debounce,
loading, 1/20/0 results, errors and dismissal. New-task composer geometry, folder
icons/insertion, exact directory ranking and plain-folder empty directories also
pass. The desktop fixture uses desktop_drop's existing test transport to register
its Flutter view without native FFI; autocomplete and transcript layout use the
actual widgets. No production test hook was added.

A separate native macOS instance with temporary `AGENT_DATA_DIR` built and hot
reloaded successfully. After selecting this checkout, entering `@file_auto`
rendered `packages/desktop/lib/file_autocomplete.dart` from the embedded server.
The widget inspector confirmed the suggestion and runtime errors were empty.
That first isolated check did not update the user's open window. Subsequent
checks loaded the current build against the existing desktop data and confirmed
`@desktop` returns `packages/desktop/` first. The overlay change also accepted
native hot reload with no runtime errors. No task prompt was sent for these UI
checks.

Tradeoffs: TTL caches allow brief filename staleness, separate connections can
duplicate an initial scan, and very large trees return a bounded partial index.
Async filesystem APIs cannot guarantee disk/NFS latency. Delayed acknowledgements
and obsolete replies were simulated locally; this is not a cellular-network,
cross-platform or long-duration capacity benchmark.

## 2026-10-31 — Code-mode output budgets

Replace the 65,536 UTF-16-unit exception in `text()` with Codex's bounded
collection and response truncation. Two ordinary shell results could exceed
that old check and fail an otherwise successful cell, losing its output and
explicit state. Output pressure now preserves a fixed beginning and rolling
end, reports omissions, and lets the cell finish.

Default the response to 10,000 approximate tokens and honor a first-line
`// @exec: {"max_output_tokens": 20000}` override. Validate pragma fields as
non-negative JavaScript-safe integers; null uses the default, and zero retains
only truncation diagnostics for nonempty output. Estimate one token per four
UTF-8 bytes, preserve code-point boundaries, and place warning/omission text
outside the retained-text budget. Text-only results that fit retain their item
boundaries; oversized results combine their text for head/tail truncation.

Bound collection inside QuickJS to 1 MiB of text and 32,768 logical items before
crossing FFI, independently of the requested response budget. Retain a fixed
prefix and rolling suffix with explicit loss counts. Prefix/suffix cursors avoid
copying the entire retained tail after every small write. A split text item
continues its original line across the omission notice. The public result keeps
the existing `output`/`values` shape. The tool description advertises the output
override; `yield_time_ms` remains an ignored comment field, and this change does
not implement yielded cells or media output.

Source evidence: local Codex `a795f961be68383738e56ac396742b3e8451696a`, compared
with the previously pinned `2681f8cba2831ef72bca2c0672b2e49d5f690745`. The relevant
budget, collection and formatting sources are identical between these revisions:

- `codex-rs/code-mode-protocol/src/runtime.rs`, `description.rs`, and `host/mod.rs`;
- `codex-rs/code-mode-runtime/src/output/output_collection.rs`;
- `codex-rs/utils/output-truncation/src/lib.rs` and
  `codex-rs/utils/string/src/truncate.rs`.

Reproduce source reads with `git show REVISION:PATH` in the Codex checkout and
compare with `git diff OLD_REVISION NEW_REVISION -- PATH`. Verification on macOS
arm64, Dart 3.13.7:

    dart test test/code_mode_test.dart -r expanded
    dart analyze packages/code_mode packages/agent/lib/src/tool_specs.dart test/code_mode_test.dart
    dart test -r expanded
    git diff --check

The batched-output regression first failed with `Cell output limit exceeded`.
All eight cell lifecycle tests now pass, including continuation/state after
80,000 characters, token overrides, zero/default budgets, UTF-8 truncation,
invalid pragmas before host dispatch, multi-megabyte output, item pressure,
cancellation and CPU interruption. Scoped analysis passes; no formatter was run.
The final full-suite run in the concurrently changing checkout passed 58 tests
and failed two newly added cases: `turns have no step limit, including resumed
tasks with legacy limits` (the separate agent step cap) and `GPT http resets its
five-minute event idle limit and releases a silent stream` (a test timeout).
The earlier RPC-deadline failure passed in isolation and on this full rerun.

Tradeoffs: token counts are Codex's byte estimate, not tokenizer measurements.
Large budgets cannot recover text already discarded by collection. This matches
the text-output limits and truncation policy, not the complete Codex runtime;
QuickJS's separate memory, CPU, source and store limits still apply. Evidence is
from the real embedded QuickJS boundary and local provider fixtures, not a new
live-model or cross-platform run.

## 2026-10-31 — GPT reasoning changes on active-task messages

User requirement: allow the desktop to change GPT reasoning while a task is
running. Keep the existing composer contract: a selection accompanies the next
message. Steer applies it within the active turn at the next model boundary;
Queue retains it with that message until its turn starts. Selecting a level
alone does not submit input or interrupt an in-flight provider request.

Allow `reasoning` on active `task.send` requests, validate it against the frozen
task model/settings before admitting input, and wait for startup configuration
when a message arrives immediately after task creation. Recheck the current task
owner after asynchronous validation. Keep model/provider changes prohibited and
retain DeepSeek/OpenCode's fixed-effort policy.

The agent commits a changed effort immediately before its associated user input
in one batch with `effective_reasoning`. Each steered message can select its own
effort; queued messages retain their selected effort independently. Repeated
levels add no update. The existing GPT adapter emits `configuration_update` and
keeps the original top-level reasoning and earlier input untouched. Cancellation
or archive discards uncommitted input and its effort together. The desktop keeps
a newer unsent selection when earlier configuration events arrive.

Sources inspected on macOS arm64, Dart 3.13.7, Flutter 3.47.8:

- Pinned Codex `2681f8cba2831ef72bca2c0672b2e49d5f690745`,
  `codex-rs/protocol/src/models.rs` and `models/configuration_update.rs`, using
  `git show COMMIT:PATH`: a durable configuration item carries reasoning effort
  and takes effect at its history position. No new GPT wire shape was introduced.
- The [OpenAI reasoning guide](https://developers.openai.com/api/docs/guides/reasoning#change-reasoning-mid-conversation),
  read 2026-10-31: append updates between responses before user input, retain the
  original request-level effort, preserve update positions, and avoid adjacent
  updates. The existing compaction restoration contract remains unchanged.

Verification: the widget and UDS session regressions first failed because the
desktop kept the running task at `low`. After enabling the selector alone, the
session regression failed with `Change task settings between turns`. Both pass
after the server/agent repair. The session fixture checks a steered `high` and a
queued `max`, exact update placement, stable earlier prefixes and top-level
settings, invalid effort rejection, unsent selection preservation, and restart.
Existing server checks now cover immediate-start admission and archive discarding
the queued effort; both Console provider identities reject changed effort before
pending-message admission. These use local protocol fixtures, not new live GPT
inference or cache-hit measurements.

Reproduce from the repository root, without running the Dart formatter:

    dart test --reporter expanded
    dart analyze
    cd packages/desktop
    flutter test --no-pub test/session_test.dart test/view_test.dart --reporter expanded

All 55 repository tests and whole-repository analysis pass. The full desktop run
passes the reasoning checks but currently has three failures in the concurrently
added `dictation_test.dart` (Stop hit testing and recording cleanup). Those
dictation changes are outside this repair. Pending effort remains memory-only
until its message is committed, matching the existing pending-input policy.

## 2026-10-31 — Composer dictation and direct desktop uploads

User requirement: copy `harness/client` dictation into the desktop composer and
use its architecture with the minimum audio hops. One desktop-owned service
captures the local microphone and sends multipart WAV directly to OpenAI's
`/backend-api/transcribe`. The task server never receives audio, Base64 chunks,
or transcription responses. Only the final text enters a task when the user
sends it. This replaces the unfinished server-relay implementation in the
working tree.

Keep authentication refresh in the existing network-isolate owner. The local
desktop requests access credentials through `auth.desktop` over its private
UDS connection; TCP listeners reject that method. No refresh token is returned.
The desktop rechecks the account before uploading and after a 401 refresh.
Login, logout, disconnect, composer navigation, Escape, and application shutdown
cancel owned work. Audio remains in memory for the current attempt and manual
retry, and is cleared after completion or cancellation. Transient retries reuse
the prepared bytes and authorization; they do not relay audio or refresh the
account on every retry. Credentials and HTTP error bodies are excluded from
diagnostics, telemetry, and task history.

Use the reference's compact 28-to-72-pixel microphone control, six-bar RMS
waveform, spinner, Stop, Cancel, and retry rail. The editor and model controls
stay mounted. Stop inserts at the current selection with the reference's
Unicode spacing; Enter finishes and sends once. IME composition defers insertion.
Recording shorter than 250 ms is discarded; 595 seconds finishes the recording.
The macOS bridge emits 16 kHz mono PCM16 with the reference's gain processing.
Microphone permission is requested only after explicit activation; a denial
offers the system microphone settings.

Reference: Harness commit `6b595ec8a160d7d0c0b5dae0a7352793944fe1d5`, inspected
as local source on macOS arm64, Dart 3.13.7, Flutter 3.47.8:

- `client/lib/services/dictation_service.dart`: local auth ownership, direct
  HTTP, capture phases, duration bounds, same-audio retry, cancellation, and
  default non-streaming behavior.
- `client/lib/services/desktop_backend_auth.dart` and
  `desktop_http_session.dart`: local backend authorization and client-owned HTTP.
- `client/lib/ui/dictation_controls.dart`, `composer_dictation_session.dart`,
  `client/macos/Runner/DictationAudioBridge.swift`, and
  `client/docs/compact-dictation-reference.md`: compact controls, native capture,
  editing and insertion semantics. Reproduce with `git show COMMIT:PATH` in the
  Harness checkout. The inspected files are clean at that revision.

Adaptation: keep Happen's credential owner and HTTP client identity. This ports
the reference's default non-streaming composer path; experimental live partials,
sidebar badges, global dictation shortcuts, recording history and settings are
outside the requested composer scope. Happen does not claim Harness's complete
workspace-policy/routing or browser-session implementation. The desktop has one
small reusable HTTP pool in addition to the task network owner; this avoids
audio serialization and server forwarding while retaining coalesced refresh.

Verification commands (no Dart formatter):

    dart test test/dictation_test.dart -r expanded
    cd packages/desktop
    flutter test --no-pub test/dictation_test.dart -r expanded
    flutter build macos --debug --no-pub
    cd ../..
    dart analyze packages/desktop packages/server packages/gpt/lib/src/transcription.dart test/dictation_test.dart
    git diff --check

The original composer tests reproduced premature hit testing during the pill's
expansion and a framework notification during navigation cleanup. Checks now
target the continuously visible Stop slot; cancellation publishes after native
release so the new composer is not rebuilt during disposal. Final verification
also reproduced focus loss after Retry and Escape cancelling an active IME
composition. The controls now share the editor's tap region, and Escape defers
to composition.

Verification: all five direct-transcription transport tests and all 23 desktop
tests pass, including the six composer dictation cases. Scoped analysis,
`git diff --check`, and the native debug macOS build pass. The broad repository
run passed 61 tests and failed the concurrently changed image-attachment server
test with `ImageException: Invalid IDAT checksum`; dictation did not introduce
or modify that image path.

MCP hot reload succeeded in the running desktop and the subsequent runtime-error
check was empty. The loaded widget tree includes the composer and DictationButton
with no ErrorWidget. A read-only native `status` call confirmed that the loaded
runner has the microphone bridge, 16000 Hz capture, permission already granted,
and no active recording. No live microphone recording or OpenAI audio upload was
made during verification; recognition quality and actual device audio remain
unmeasured. Transport tests use a local HTTP fixture, separate from that native
bridge check. No Dart formatter was run.
The native Happen app rebuilt with `flutter run -d macos --debug --hot --print-dtd`,
accepted hot reload, and reported no runtime errors. No Dart formatter was run.

## 2026-10-31 — Cancellation-owned turns and Codex stream deadlines

The reported desktop error exactly matches `callIsolate`'s default ten-minute
deadline. The server applied it to the complete agent turn, including model
requests and tool work; the agent independently applied it to model responses and
compaction. Progress could not extend either timer. When the outer timer fired,
the server stopped observing durable events and reported a transient failure.

Follow the user's local Codex checkout: turns and model/compaction calls have no
cumulative wall-clock deadline. Allow an explicit null `callIsolate` timeout only
with caller-owned cancellation. Other RPCs retain their deadlines. The server
observes the turn until its terminal event and reply; Stop, archive and shutdown
continue cancelling the agent through its mailbox. The observation token is
released with that invocation. Nested model calls use the existing turn token.
Worker exit detection and per-tool execution bounds remain active.

GPT HTTP/SSE and WebSocket wait up to five minutes for each provider event. Match
Codex's fifteen-second WebSocket connection limit and absence of a total HTTP
response deadline. Measure idleness around each iterator `moveNext` future.
Putting `Stream.timeout` outside the asynchronous SSE decoder caused an idle
error to wait for decoder cancellation before reaching the consumer; a silent
fixture remained stuck until the test's thirty-second deadline. A future timeout
reaches the transport's cleanup immediately, which releases its owned raw input
subscription and leaves the shared HTTP pool usable. Provider credentials and
stream contents are excluded from these errors.

Pinned sources inspected with `git show REVISION:PATH` in
`/Users/meoyawn/Developer/github/codex`, revision
`a795f961be68383738e56ac396742b3e8451696a`:

- `codex-rs/core/src/tasks/mod.rs` and `tasks/regular.rs`: task-owned cancellation,
  spawned turn future and regular turn loop without a duration deadline.
- `codex-rs/model-provider-info/src/lib.rs`: 300,000 ms stream-idle default and
  15,000 ms WebSocket connection default.
- `codex-rs/codex-api/src/sse/responses.rs` and
  `endpoint/responses_websocket.rs`: timeout around the next transport event.
- `codex-rs/codex-client/src/provider.rs`: requests start with `timeout: None`.

Verification on macOS arm64, Dart 3.13.7 and Flutter 3.47.8:

- The accelerated server regression failed before the fix with the screenshot's
  exact `TimeoutException after 0:10:00.000000` error. It passes after removing
  the turn deadline, completes the response and queued follow-up durably, and
  checks that task owners are released. Only the server's long RPC timers are
  accelerated; its real agent, storage and network owners perform the work.
- Both GPT transport regressions first failed against the original client with
  `TimeoutException after 0:03:00.000000: No stream event`. They pass with the
  five-minute event waits and exercise the shared-pool behavior after silence.
- The native Happen app accepted hot reload and reported no runtime errors.
- The final whole-repository run passed 61 tests; `dart analyze` and
  `git diff --check` were clean. The eight focused desktop app/session/conversation
  checks passed. The full desktop run passed 20 checks and failed the same three
  dictation cases already recorded above (Stop hit testing and recording cleanup).

Reproduction from the repository root, without running the Dart formatter:

    dart test test/server_test.dart test/gpt_test.dart -r expanded
    dart run tool/verify_long_turn.dart
    dart test --reporter expanded
    dart analyze
    flutter test --no-pub packages/desktop/test --reporter expanded
    git diff --check

The separate real-time probe holds HTTP/SSE and WebSocket model responses for
606 seconds, with periodic events and ordinary UDS task-status requests. This
crosses both former ten-minute deadlines without changing production timers.
The run confirmed both turns still running and status requests responsive at
600 and 606 seconds. Its provider fixture then overlapped an unawaited flush with
close. After serializing and awaiting fixture writes, a ten-second rerun checked
two durable completions, unchanged request count and zero retained task owners.
Completion after the full 606 seconds was not rerun. The optional seconds
argument selects a shorter fixture check: `dart run tool/verify_long_turn.dart 10`.

These runs use a local provider fixture and temporary task data, not live-model,
cross-platform, mobile-network, or multi-week availability evidence. Without a
total turn deadline, an unresponsive worker requires cancellation or worker-exit
handling; increasing task duration does not itself authorize a timeout.

## 2026-10-31 — Unlimited model steps and bounded stream recovery

The user clarified that tasks may run for 24, 48, 72 hours or longer, then
selected the local Codex checkout as the behavior reference. In addition to the
deadline repair above, remove the agent's model-step cap, its saved configuration
default and CLI `--max-steps`. Ignore legacy `max_steps` when resuming tasks.
Compaction and targeted durable history access retain their existing behavior.
Stop/archive/shutdown, model completion and terminal failures still end a turn.
This does not add execution after quitting the desktop or automatic crash/restart
continuation.

Read-only inspection of attachment task `a0164f4f58a4917078ee5e0e1008c84b` found `turn.started` at
`2026-10-31T00:47:31.719679Z`, its last completed cell at sequence 60, and
`turn.cancelled` at `2026-10-31T00:57:31.715202Z` (sequence 61). The dictation task
also cancelled exactly ten minutes after starting. The cell output overflow in
the screenshot was followed by more successful calls, so it was not the terminal
event. The saved 64-step limit would independently stop a longer continuation.
The task database's `events` table can reproduce the timestamps without reading
prompts, tool contents or credentials:

    SELECT seq, type, created_at FROM events
    WHERE type IN ('turn.started', 'turn.cancelled') OR seq IS 60 ORDER BY seq;

Allow five retries for disconnected/idle GPT streams, socket/HTTP/WebSocket
connection failures, timeouts and retryable server errors. Use Codex's 200 ms
exponential backoff with ten-percent jitter and cancellation during backoff.
Reuse the same model input; only a complete response reaches the agent's tool
executor. Executed tools retain their durable results and are not repeated by
transport recovery. Explicit `response.incomplete`, authentication/validation/quota
errors and context overflow remain terminal here; the agent retains its separate
bounded context-overflow compaction path. This adopts the relevant recovery
behavior, not all Codex transport features: server retry advice, transport fallback
and optional unbounded connection retries remain unimplemented.

Send ephemeral `model.retrying` events with bounded attempt counts. The desktop
clears abandoned partial text and shows reconnecting progress until output
resumes. Preserve unsequenced terminal notifications in the task's UI projection
so an early worker failure appears in the transcript and survives widget/task
rebuilds. Clear that transient terminal state on a new turn or a durable terminal
event. It is not a replacement for server-owned durable history.

Additional sources inspected at Codex revision
`a795f961be68383738e56ac396742b3e8451696a`:

- `codex-rs/core/src/session/turn.rs` continues while follow-up work or pending
  input remains, with no duration or step cap. The earlier pinned revision
  `2681f8cba2831ef72bca2c0672b2e49d5f690745` has the same continuation policy.
- `codex-rs/core/src/responses_retry.rs` implements bounded stream recovery and
  reconnecting notices; `codex-rs/model-provider-info/src/lib.rs` defaults to five
  stream retries. `codex-rs/protocol/src/error.rs` distinguishes retryable streams
  and connections from terminal incomplete responses.
- `codex-rs/async-utils/src/backoff.rs` defines the retry delays and jitter.
  Reproduce with `git show REVISION:PATH` in `/Users/meoyawn/Developer/github/codex`.

Verification on macOS arm64, Dart 3.13.7, Flutter 3.47.8, without a formatter:

    dart test test/server_test.dart test/gpt_test.dart --reporter expanded
    flutter test --no-pub packages/desktop/test/app_test.dart packages/desktop/test/session_test.dart packages/desktop/test/conversation_test.dart --reporter expanded
    dart test --reporter expanded
    dart analyze
    git diff --check

The server clock regression fails with the original ten-minute deadline and
passes through simulated 24, 48 and 72 hours, then verifies explicit cancellation
and its committed terminal event. The continuation regression first failed at
64 model steps, then passed two 70-cell turns, including a resumed task with a
saved one-step limit. Recovery first failed on a disconnected model response,
then passed after two disconnections with one executed tool and two committed
model replies. Both GPT transports check idle-clock reset, five-retry exhaustion,
cancellation during backoff and pool reuse. Explicit incomplete responses are
not retried. The desktop regression first failed to show an unsequenced error
and then failed to show reconnecting progress; both now pass, including rebuild
and subsequent-turn clearing. Native Happen accepted hot reload.

The final full server suite passes all 61 tests; whole-repository analysis and
whitespace checks pass. The focused desktop conversation/session suite passes
eight tests. The full desktop run passes 20 tests and fails three separate
dictation cases in the concurrently edited checkout (Stop hit testing, retry and
navigation cleanup), matching the earlier failures outside this repair. Native
hot reload reports no runtime errors.

The real-time HTTP/SSE and WebSocket probe observed both tasks still running and
responsive at 600 and 606 seconds. Its first release hit a fixture-only
`StreamSink is bound to a stream` race from closing during an unawaited flush.
The fixture now serializes and awaits its writes. A corrected
`dart run tool/verify_long_turn.dart 12` run completes both turns durably, observes
no retries and releases all task owners. The 606-second run establishes continued
execution across the old deadlines; durable completion is verified separately by
the corrected shorter probe and automated server tests.

These are local transport fixtures and accelerated-clock observations, not a
72-hour soak, new live-provider inference or cross-platform evidence. Terminal
service failures can still stop work; unlimited duration does not guarantee
provider availability or operating-system uptime.

## 2026-10-31 — Local macOS desktop launch and release workflows

Initial implementation and verification. The stop-only reinstallation policy
in the following entry supersedes the restart behavior recorded here.

User requirements: follow the Spotify checkout's debug hot-reload and release
reinstallation workflows, allow one debug and one release instance, and keep
all workflow state outside the application. The standalone `release` target
must only build; it must not log, lock, inspect, launch, or reuse app processes.

`moon run release` directly invokes `flutter build macos --release` in
`packages/desktop`. It has no Python wrapper or workflow state. Ordinary Flutter
and Moon build output/caches remain standard build-tool behavior. Installation
and process management belong to `release-reinstall`; `reinstall-release` is
its alias. The dependency builds first, then the installer verifies identity,
required native frameworks, and the deep/strict code signature before staging
and replacing `/Applications/Happen.app`. Failed replacement validation restores
the previous bundle. An installed release is restarted only if its exact
executable was running; debug remains running independently.

`moon run dev` uses a standard-library Python launcher with a checkout-local
launch lock, live executable discovery, and Flutter supervisor discovery by
working directory. Include the Flutter shell entrypoint before it execs the
snapshot, so simultaneous cold launches also reuse startup. A debug process is
recognized by this checkout's Debug bundle; release discovery excludes Flutter's
Debug/Profile product paths. Separate mode checks allow one of each. Existing
duplicates produce PIDs and exit status 2 instead of another launch. There is
no runtime singleton code or new Dart dependency.

New debug sessions expose a FIFO for `r`, `R`, and `q`, private build output,
and supervisor metadata. All of these, plus launch/reinstallation locks, live
in the repository's ignored `.local/run/`, outside `Happen.app`. An existing
externally started debug session retains its terminal/VM controls. At the user's
request, release launch/reuse is internal to reinstallation, with no separate
Moon launch target. Reinstallation uses the guarded launcher's release path,
shares its launch lock and rechecks the full executable path before SIGTERM;
it never signals the debug app by a name-only match.

Reference: `/Users/meoyawn/Developer/spotify` at
`24975638f3ccf55111c60ef38831fb8d2bb9368f`, `tools/run_flutter.py`,
`tools/release_macos.py`, `moon.yml`, and `README.md`. Reproduce source inspection
with `git show REVISION:PATH` in that checkout. Happen adapts its bundle identity,
native framework verification, and Python invocation, separates the instance
checks by mode, and makes standalone release building a direct Flutter command
per the user's clarification. No Python packages are required.

Verification environment: macOS 26.4 arm64, Python 3.9.6, Flutter 3.47.8,
Dart 3.13.7, Moon 2.6.5. From the repository root:

    python3 -m unittest discover -s packages/desktop/tool -p 'test_*.py' -v
    moon run dev -- --status
    moon run dev
    moon run release
    python3 docs/evidence/desktop-workflows.py.txt
    git diff --check

The native verification script requires one live debug session and no running
release. It installs into a temporary directory with spaces and a `Debug`
ancestor, uses a temporary `AGENT_DATA_DIR`, injects a post-replacement validation
failure, and stops/unregisters/removes its release afterwards. Child commands
receive no inherited `MOON_*` settings from a hosting application's workspace.
The launcher tests use real subprocesses, `ps`,
`lsof`, file locks and FIFO I/O with a local Flutter stand-in; they cover eight
concurrent starts, reuse, input delivery, exit/relaunch and duplicate refusal.

Eight concurrent requests reused the live debug app and supervisor. The signed
63.9 MB release built successfully; both built and installed bundles contained
no workflow logs, locks, metadata, or launch scripts. Temporary installation
left a stopped release stopped. Eight concurrent release requests reused one
process. Reinstallation changed its PID; fault injection restored the previous
executable's inode and restarted it. The original debug app/supervisor PIDs
remained unchanged throughout. No Dart formatter was run.

After making standalone `release` a direct Flutter invocation, another native
build passed and every file's size/mtime in `.local/run/` remained unchanged.
Signature verification was performed separately after the build, outside that
target. The installer retains all verification and process management.

Incremental installation validation also exposed a stale outer app signature:
`App.framework` verified independently, but the app's sealed framework hash
still referred to the preceding build. The outer signature was timestamped
04:20:30 while the newly embedded framework was timestamped 04:21:47. The
installed Flutter SDK at `737ba8f885dc774b53b442759999a312c9461e4e`,
`packages/flutter_tools/bin/xcode_backend.dart`, copies and re-signs that
framework in the embed script; its Xcode template declares no script outputs.
Declare the embedded `App.framework` directory as that phase's output so
Xcode's outer signing task observes its updates. The next direct release build
passed deep/strict verification. This changes build dependencies, not signing
identity or runtime behavior. The source reference and failure can be checked
with `codesign --verify --deep --strict --verbose=4` on both the app and its
embedded framework; the outer `Contents/_CodeSignature/CodeResources` records
the sealed nested hash.

A subsequent incremental release build refreshed the outer signature again and
passed deep/strict verification. The final temporary install/restart/rollback
probe passed with debug app PID 52001 and Flutter PID 50665 unchanged. A managed
native debug session also reported `Reloaded 0 libraries in 96ms` through its
local Flutter controls. Built and installed bundles still contained no workflow
logs or locks.

Tradeoffs: the guard applies to these checkout-local commands. Direct Flutter
or executable launches can bypass it, and other checkouts do not share its lock.
No application-level enforcement, Windows support, notarization, or crash/power-
loss atomicity across the two directory renames is claimed. Rollback evidence
uses an injected validation failure, not a real disk or signing-service failure.

## 2026-10-31 — Live composer dictation and a Settings screen

The user expanded composer dictation to show words while speaking, requested a
saved Live / On stop choice, and requested Settings as a separate screen. Live
is the default when no preference is saved. Store `dictation_mode` in the
desktop's existing settings table; capture the mode once per recording. A
normal navigation route replaces the Settings dialog, with a Back button and
the existing account, provider, delivery, and archived-task controls. The chat
route remains mounted so returning preserves its draft and conversation.
Opening Settings cancels an active recording before covering the composer.

Use the live branch from Harness at the same pinned revision
`6b595ec8a160d7d0c0b5dae0a7352793944fe1d5`,
`client/lib/services/dictation_service.dart` and
`client/lib/ui/composer_dictation_session.dart`. Reproduce inspection using
`git show REVISION:PATH` in `/Users/meoyawn/Developer/harness`. The service uses
`/backend-api/dictation/stream?dictation_surface=composer` with the
`chatgpt-dictation` and `codex-desktop` subprotocols, PCM16 session configuration,
`audio.append`, segment/final revisions, and explicit session close. Happen
retains its own HTTP user agent and originator. This is the explicitly selected
live path; it does not infer account entitlements from a remote feature gate.

Audio still travels directly from the desktop to OpenAI. The local UDS backend
supplies credentials once before capture; no audio, interim transcript, or
provider response enters the task server. Buffer microphone frames during the
handshake and replay them once after session startup. Startup/handshake waits
are bounded to ten seconds each and finalization to eight seconds, all owned
by the recording's cancellation token. Socket errors, missing final segments,
and unexpected session closure fall back to the existing direct HTTP upload
of the retained complete recording. The composer reports that fallback while
recording. Cancellation closes the owned connection and prevents fallback.
Redirects are refused so account credentials are never forwarded to another
endpoint. Only final user-submitted text becomes task history.

The editor now updates the active dictated range as revisions arrive. Preserve
manual edits and cursor movement, defer updates through IME composition, and
restore only untouched dictated ranges on Cancel. Final revisions use a counter
independent from partial revisions, so a lower-numbered first final is accepted.
Keep partial text available when transcription fails and the user can retry.
Happen has plain text rather than Harness's inline mention atoms. Limit the
token edit matrix to 250,000 cells for unusually large ASR replacements; beyond
that bound, preserve the manually consumed prefix without trying to realign
every token. This avoids quadratic work on the UI thread.

Verification environment: macOS 26.4 arm64, Dart 3.13.7, Flutter 3.47.8. No Dart
formatter was run. The wire fixtures cover partial/final ordering, cancellation
during handshake/startup/recording/finalization, incomplete finalization, and
redirect refusal. Composer checks cover live updates before Stop, unchanged
per-recording mode, Cancel, Enter sending once, complete-audio HTTP fallback,
manual edits, and restoring drafts on navigation. The navigation check initially
failed because the editable widget had detached before rollback; the composer
now restores its controller directly during disposal. Existing Settings and
session checks cover the full screen, Back preserving the draft, saved mode,
and restoration after reopening the database.

The live OpenAI probe used generated Samantha speech converted to 16 kHz mono
PCM16, streamed in real time through the same production transport and the
running desktop's local credential owner. It received 21 updates before Stop;
the first arrived 2,563 ms after starting authorization/connection. The final
transcript at 8,917 ms exactly matched the generated two-sentence input. No
microphone recording or private conversation was used for this network probe.
The existing native microphone bridge is unchanged.

Reproduction commands from the repository root:

    dart test test/transcription_stream_test.dart test/dictation_test.dart -r expanded
    flutter test --no-pub packages/desktop/test/dictation_test.dart packages/desktop/test/session_test.dart -r expanded
    flutter test --no-pub packages/desktop/test/view_test.dart --plain-name Settings -r expanded
    dart analyze
    git diff --check
    say -v Samantha -o /tmp/happen-live-dictation.aiff 'The quick brown fox jumps over the lazy dog. This is a test of live dictation in the desktop composer.'
    afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/happen-live-dictation.aiff /tmp/happen-live-dictation.wav
    dart run tool/verify_dictation.dart SOCKET_PATH /tmp/happen-live-dictation.wav

`SOCKET_PATH` is the private Unix socket of a running Happen desktop, discoverable
with `lsof -n -U -a -p APP_PID`. The probe prints timings, transcript lengths,
and the supplied audio's final text, never credentials. Hosted-service access,
network conditions, and the upstream five-minute live-session lifetime can
still trigger the on-stop fallback. This is one successful account/environment
probe, not cross-platform or long-duration service availability evidence.

Final verification passes all 72 repository tests and all 35 desktop tests.
Whole-repository analysis and whitespace checks pass. The running desktop
accepted hot reload and reported no runtime errors. Earlier full runs caught
transient errors in the concurrently edited attachment code; the final complete
runs above include that code and pass.

## 2026-10-31 — Reinstallation leaves the release stopped

User correction: reinstallation must stop the old release and install the new
bundle without restarting it. This replaces the initial Spotify-derived policy
of restoring the release's running state. Successful installation and rollback
both leave the release stopped; opening it afterwards is a separate user action.

Keep the existing full-executable-path check before SIGTERM and wait for exit
before replacing the bundle. Keep signature/framework validation, staged
replacement, rollback and local locks. Remove the restart helper and all calls
to it, including the rollback path. Remove the debug launcher's unused release
launch flags as well; no production caller needs them now. Debug launch/hot
reload and the standalone build-only `release` target retain their behavior.
Update the Moon task description and user documentation to state stop-only
reinstallation. No application code, runtime logging, or bundled locks changed.

Verification on macOS 26.4 arm64, Python 3.9.6, using the existing signed release
bundle and a running debug session:

    python3 docs/evidence/desktop-workflows.py.txt
    python3 -m unittest discover -s packages/desktop/tool -p 'test_*.py' -v
    moon query tasks
    git diff --check

The updated native check failed before the fix with `Reinstallation must leave
the release stopped`. After the fix it passes initial stopped installation,
stopping a live release without relaunch, and injected post-replacement
validation failure restoring the previous executable's inode without relaunch.
It uses a temporary installation and data directory, then unregisters/removes
them and reaps its child processes. Debug app PID 60675 and Flutter PID 59586
remain unchanged; no tooling logs/locks appear in the installed bundle. Both
launcher tests pass. No Dart formatter or additional native build was needed.

The existing limits on direct launches, other checkouts and crash/power-loss
atomicity still apply. Rollback is verified through fault injection rather than
a real disk or signing-service failure.

## 2026-10-31 — Composer attachments and large images across machines

User requirements: image paste and image/file drag-and-drop following Harness,
image inputs through both desktop and server, Codex's source limits and model
resize policy, and large images across machines. The final remote requirement
is explicit: the desktop must prepare a 100 MiB image to fit the transport limit.
Earlier proposals to use small chunks for remote images are superseded.

The macOS clipboard bridge captures original image representations and file
URLs, distinguishes an image copy from rich text containing an incidental image,
and stages image files outside the bundle. HEIC/HEIF clipboard data is converted
to PNG because the shared Dart decoder does not support that format. Ordinary
text paste still passes through Flutter's editing action. `desktop_drop` consumes
promised/provider files before the native drop lifetime ends; transient files
are copied to owned storage. The composer displays removable previews, supports
image-only messages, retains drafts on failure/cancellation, and releases owned
image copies only after admission or removal. Thumbnail decoding is bounded;
the native clipboard and file copying preserve the original pixels.

`ConversationItem` now admits typed image and file parts. Server preparation runs
in a cancellable isolate before admission. Local images arrive as absolute
server paths; remote images arrive as inline PNG/JPEG/GIF/WebP bytes. Sources
are bounded to 1 GiB. Default high detail uses a 2,048-pixel edge and 2,500
32-pixel patches; original detail uses a 6,000-pixel edge and 10,000 patches.
The dimension calculation is ported from Codex. Resizing retains the source
PNG/JPEG/WebP format, uses JPEG quality 85, preserves transparency, and converts
other supported formats/GIF frames to PNG. The Dart image encoder/interpolator
is not byte-identical to Rust's implementation; EXIF orientation is baked into
resized output. This is shared code used by server and desktop as needed.

Cross-machine desktop submission uses Codex's 32 MiB encoded image budget inside
the 64 MiB WebSocket limit. It snapshots small originals unchanged when they fit
the combined budget. Otherwise it prepares the largest sources first, using
the same image policy in a cancellable worker isolate. Originals stay available
for retry. A group that still exceeds the budget returns an error without
sending or clearing the draft. Codex's pinned remote composer instead rejects
oversized originals before snapshotting; automatic preparation is the requested
extension. It is deliberately not another quality ladder or a smaller limit.
The app's existing remote `AgentClient` path implements this; remote server
selection/SSH management still need a desktop UI.

Ordinary remote files use connection-owned staged uploads: begin, append with
exact offsets, finish, and cancel. Blocks carry up to 24 MiB of source bytes
(32 MiB base64), derived from that same budget; the client coalesces filesystem
reads instead of sending one RPC per small disk read. Upload IDs cannot be
consumed by another connection. Partial uploads are removed on cancellation or
disconnect, and acknowledged retries start a new upload from the retained file.
Accepted files move to unique durable server paths. The API also supports
explicit image uploads for non-desktop clients; accepted images are deleted
after their prepared bytes are handed to the task. Local ordinary files remain
path references. Folder paths work on a shared filesystem; remote folders must
be represented as individual files.

Prepared image bytes live in canonical conversation records, so restart, fork
and export/import preserve images without relying on a client cache. Ordinary
file paths are references and require their server files to remain available.
GPT receives Responses `input_image`; native DeepSeek receives Messages base64
image blocks; its Chat/OpenCode adapter receives `image_url` parts. File parts
become quoted path context. GPT checkpoint decoding preserves image detail.
Image token estimates use Codex's image heuristic instead of counting base64
as text; the initial integration test exposed premature compaction without this.
Search indexing records image names/types rather than their base64 payloads.

Client frames, notification backlog bytes, and active context are bounded to
64 MiB. History pagination uses a SQLite cursor and byte budget as well as its
row limit, leaving large records whole. Desktop pagination continues until an
empty page. Text remains bounded to 512 KiB, with 32 pending messages and a
separate serialized pending-input budget. Provider calls, tool output and
unrelated protocol limits retain their existing owners.

Sources inspected:

- Codex `a795f961be68383738e56ac396742b3e8451696a`,
  `codex-rs/utils/image/src/lib.rs` (source guard, dimension math and formats),
  `codex-rs/protocol/src/local_media.rs` (portable image snapshots),
  `codex-rs/tui/src/chatwidget/image_submission.rs` (32 MiB remote input budget),
  `codex-rs/app-server-transport/src/transport/websocket.rs` (64 MiB messages),
  and `codex-rs/core/src/context_manager/history.rs` (image token estimates).
  Reproduce with `git show REVISION:PATH` in
  `/Users/meoyawn/Developer/github/codex`.
- OpenCode `fa96f42f6cd8bf21f11fd5b38d78e2dd34d5563e`,
  `packages/ai/src/protocols/open-responses.ts`, `openai-chat.ts`, and
  `packages/core/src/session/runner/to-llm-message.ts`; DeepSeek harness
  `ce7073d51254c26cd63b22a60835b8f948deb447`,
  `packages/llm/llm-deepseek/src/serialize.ts`.
- Harness's `client/lib/services/composer_clipboard.dart`,
  `conversation_image_preparation.dart`, `client/lib/ui/chat_view.dart`, and
  `client/macos/Runner/ClipboardBridge.swift`; its checkout at final inspection
  was `6b595ec8a160d7d0c0b5dae0a7352793944fe1d5`.
- Resolved `desktop_drop` 0.9.2 native transport/drop lifetime APIs and `image`
  4.12.0 codecs. Exact package versions and checksums are in `pubspec.lock`.

Verification on macOS 26.4 arm64, Dart 3.13.7 and Flutter 3.47.8:

    dart test --reporter expanded
    flutter test --no-pub --reporter expanded # from packages/desktop
    dart analyze
    python3 packages/desktop/tool/run_flutter.py
    git diff --check

The full suites pass 72 server/runtime tests and 35 desktop tests. A real
uncompressed 64 MiB-plus BMP crossed TCP in three acknowledged blocks, with
source files deleted before admission, and reached the provider fixture as a
1,600-square PNG. The independent desktop test starts with a 100 MiB BMP and a
small PNG; a TCP proxy inspects the actual task request and proves that the
desktop prepared the large image before transport while preserving the small
image's bytes. It checks cancellation, retained originals, and a source above
1 GiB being rejected before sending. The source-limit boundary itself is tested
without allocating a 1 GiB image. Server tests verify original-detail dimensions,
upload ownership/offsets, disconnect cleanup, and image history through restart,
fork and import. DeepSeek tests inspect both independent wire formats.

The widget paste test first exposed an invalid clipboard fixture and the drop
test exposed a real thumbnail overflow; corrected fixtures and the thumbnail
layout repair pass. Tests now verify native drop event delivery, staging before
source release, failed-send retention, retry cleanup and plain-text paste. The
actual macOS app builds and hot reloads without runtime errors. A live clipboard
smoke check through `readComposerClipboard` and the native method channel staged
one 70-byte PNG; a rich-text-plus-image fixture returned its text and no image.
The original pasteboard was restored after the controlled check.

These are local TCP/provider fixtures and a macOS native clipboard check, not
live-provider vision answers, a physical two-machine test, or a full 1 GiB
decode/transfer benchmark. Desktop Windows/Linux native paste parity is not
claimed. Large-image memory use still depends on decoded dimensions and codecs;
the image package's pixel guard remains in force. No Dart formatter was run.

## 2026-10-31 — Desktop background lifetime and explicit quit

User requirement: closing the desktop window must preserve the embedded server;
macOS and Windows have exactly two tray actions, Show and Quit. A focused
window's Command+Q first shows an overlay and requires a second press to quit.
The user confirmed in-process UDS on macOS/Linux, allowed the efficient Windows
transport choice, and requested code changes without further compilation.

Keep the Flutter engine, session, database owner and AgentServer in their
existing process. macOS intercepts window close and orders the retained window
out; a fullscreen window first leaves fullscreen. Dock reopening and Show
restore/focus the same window, including when minimized. A native template H
status item owns Show and Quit. Quit uses FlutterAppDelegate's existing native
termination request, which awaits the Dart application exit listener.

The Windows runner intercepts WM_CLOSE before Flutter's lifecycle handler,
hides the retained window, and owns a Shell_NotifyIcon menu. If the notification
area is unavailable, close minimizes instead of leaving an inaccessible hidden
window. TaskbarCreated reinstalls the icon after Explorer restarts. Show restores
and focuses the existing window. Quit calls the application's lifecycle channel;
Dart awaits the session/database/server cleanup before requesting required native
exit. Runner destruction removes the icon and releases the engine. The icon is
created after the first frame, once Dart has installed its quit handler.

DesktopLifecycle handles Command+Q on macOS and Control+Q on Windows before
focused editor shortcuts. A second distinct key-down within three seconds
confirms; key repeat cannot confirm. Escape, other input, a click, focus loss,
or timeout clears the overlay. It does not replace the editor's focus or draft.
Tray/native menu Quit bypasses this keyboard guard. Hiding never cancels the
application lifetime token; explicit quit and disposal close the existing owners.
Cleanup is coalesced, and the server is closed even when session cleanup throws.

macOS/Linux retain their private temporary UDS directory and socket permissions.
Windows startEmbedded binds 127.0.0.1 on port zero with a fresh in-memory bearer
secret; the desktop passes it directly to AgentClient.connect. The existing
WebSocket protocol and browser-Origin rejection stay in place. No named pipes,
second server process, listener discovery, or persisted credentials are added.
The desktop also accepts USERPROFILE when HOME is absent. Tokens are never
included in addresses, output, telemetry, or durable history.

The Windows runner and code-mode hook currently target x64. The pinned QuickJS
source requires GNU C and winpthreads rather than MSVC. Its Windows build hook
uses MSYS2 UCRT64 GCC, default C:\msys64\ucrt64\bin\gcc.exe, with an optional
workspace hooks.user_defines.code_mode.mingw_cc compiler path. It requests static
GCC/winpthreads linkage and explicitly exports the eight existing bridge symbols.
The upstream submodule and C ABI remain unchanged. macOS/Linux keep CBuilder.
This requires an additional Windows development compiler, with no additional
server process. Windows ARM64 and native UI execution remain unverified.

Sources inspected on macOS arm64, Flutter 3.47.8, Dart 3.13.7:

- Harness client at 6b595ec8a160d7d0c0b5dae0a7352793944fe1d5:
  macos/Runner/AppDelegate.swift, MainFlutterWindow.swift, StatusMenu.swift,
  lib/services/status_menu.dart, and docs/tray-reference.md. Its retained engine,
  native status item, fullscreen-close sequencing and Dock reopening are the
  reference. Happen intentionally uses only the requested two menu actions.
- Flutter 737ba8f885dc774b53b442759999a312c9461e4e:
  engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterAppDelegate.mm,
  FlutterEngine.mm and FlutterViewController.mm; the Windows platform_handler.cc
  and windows_lifecycle_manager.cc; and the SDK's Windows runner templates.
  Required Windows application exit posts WM_QUIT, avoiding the close-to-hide
  WM_CLOSE path. macOS key equivalents reach Flutter before native menu fallback.
- QuickJS 3d5e064e9dd67c70f7962836505a7fa067bf0a4e: Makefile's CONFIG_WIN32,
  __USE_MINGW_ANSI_STDIO and pthread linkage; bridge.c and lib/src/bindings.dart.
- [Microsoft notification-area lifecycle](https://learn.microsoft.com/en-us/windows/win32/shell/taskbar)
  and [MSYS2 compiler environments](https://www.msys2.org/docs/environments/).

Verification before stopping compilation at the user's request:

    cd packages/desktop
    flutter build macos --debug --no-pub
    flutter test --no-pub test/lifecycle_test.dart --reporter expanded

The macOS debug build and four lifecycle checks passed. The checks cover both
platform keyboard combinations, a focused editor/draft surviving the overlay,
key repeat, waiting for cleanup before process exit, dismissal and disposal,
and a real embedded UDS server answering while hidden before tray Quit closes
its client and removes its socket. The test binding substitutes only the final
process exit, since Flutter's normal test binding rejects required exit.
Scoped Dart analysis also passed. No formatter was run.

Native menu interaction, Dock/fullscreen close/reopen and Windows runtime
behavior were not exercised. No full Windows app build was run; further builds
were skipped as requested. Native changes require a rebuild/relaunch to take
effect. The user's existing desktop process was not restarted. The temporary
MinGW installation and its three newly installed dependencies were removed at
the user's request. These checks do not establish a complete Windows platform
port or crash/power-loss behavior.

## 2026-10-31 — Inline file chips in the desktop composer

User requirement: autocomplete must consume the `@` query and insert file chips
following `/Users/meoyawn/Developer/harness/client`. This supersedes the earlier
ordinary `@path` insertion decision. Keep the existing server search and wire
protocol. Enter, Tab and pointer selection insert an atomic inline reference,
showing the basename with a file/folder icon and retaining the original relative
path (including a directory's trailing slash). Sending serializes each chip at
its position as `[basename](path)`, with Harness's Markdown escaping and no `@`.
Selection reuses following whitespace or adds a space.

The editor owns one UTF-16 object-replacement position per chip and separate,
immutable offset/path metadata. The session retains these snapshots alongside
its existing per-task/project drafts. Edits move or remove metadata with the
corresponding position; duplicate adjacent markers retain their distinct paths.
Copy/cut exports Markdown paths instead of internal markers. Desktop Flutter
undo entries retain metadata through weak editing-value snapshots; dictation
rollback explicitly restores the references in its original selection. Retained
plain controllers migrate on reload without changing their editing value or
focus, after any existing dictation session releases ownership.

Source evidence: Harness `6b595ec8a160d7d0c0b5dae0a7352793944fe1d5`,
`client/lib/ui/completion_text_controller.dart` (`insertCompletion`,
`serializePrompt`, `buildTextSpan`), `client/lib/services/completion_catalog.dart`
(`CompletionEntry.serializedText`), and `client/lib/ui/inline_reference_appearance.dart`.
Reproduce with `git show REVISION:PATH` in the Harness checkout. Its retained
`client/docs/autocomplete-reference.md` describes the atomic leaf, 16 px icon,
3 px gap, medium accent label, and absence of pill background/border/padding;
the existing REA evidence is `ev_4c001694c1148856a4c8bb9cd83e60896e7189fa56f15bf3d2c9765b7f24cf81`.
Happen uses its existing Material file/folder glyphs and bounded label layout.
Flutter 3.47.8's `EditableText` passes desktop `UndoHistory<TextEditingValue>`
entries back unchanged; inspected through the Dart package-source tools.

Verification environment: macOS arm64, Dart 3.13.7, Flutter 3.47.8. Commands from
`packages/desktop`:

    flutter analyze --no-pub lib test
    flutter test --no-pub --reporter expanded
    git diff --check

Focused checks cover new/existing drafts, keyboard and pointer completion,
surrounding text, spaces and Markdown punctuation in paths, folders, navigation,
submission, duplicate-marker deletion, clipboard output, undo/redo, and cancelled
dictation. The initial cut/undo and dictation-cancel regressions restored a raw
marker without its path; both paths now preserve reference metadata. All 40
desktop tests and scoped analysis pass. The final escaping and rejected-send
checks pass all 14 controller/view tests. Whitespace checks are clean; no
formatter was run. Official MCP hot reload succeeded in the existing macOS app,
with no fresh runtime errors. Read-only inspector properties confirm that its
mounted TextField uses `ComposerTextController` and remains enabled. The active
draft was empty; no sample content was entered and no task was submitted.

Tradeoffs: draft chips remain session-local, matching the existing text-draft
lifetime. Clipboard fallback is portable Markdown; rich chip rehydration through
Harness's private native clipboard format is not implemented. Server files are
path references and are not uploaded or read by autocomplete.

## 2026-10-31 — Transient desktop quit hint

User requirement: the desktop quit confirmation should resemble Chrome's brief
dark overlay and fade away automatically. Replace the dimmed window and Material
card with a centered translucent charcoal strip, rounded corners, and one bold
white shortcut message. Show it immediately for one second, then fade it out over
200 ms. The second distinct shortcut press confirms during that first second;
key repeat still cannot quit. This replaces the earlier three-second window.

Keep the editor's focus and draft. The hint ignores pointers, while a parent
Listener dismisses it on pointer down and lets the underlying control receive
the click. Keep the live accessibility announcement and the rest of the window's
semantics available. Escape, other input, blur, and hidden-window dismissal retain
their existing behavior, as do tray Quit and awaited resource cleanup.

Reference: Chromium `445cb045e270111ab38ba7beb2964c4ac4efce72`,
[`chrome/browser/ui/cocoa/confirm_quit_panel_controller.mm`](https://github.com/chromium/chromium/blob/445cb045e270111ab38ba7beb2964c4ac4efce72/chrome/browser/ui/cocoa/confirm_quit_panel_controller.mm).
Its frame uses 75% gray-0.2 fill, bold 24-point white text, and 20-point corners
on macOS 26. `dismissPanel` waits one second; `animateFadeOut` lasts 0.2 seconds.
Retrieve that pinned raw file with `curl -fsSL` to reproduce the source inspection.
Happen keeps its existing double-press interaction rather than adding hold-to-quit.

Verification on macOS arm64, Flutter 3.47.8, Dart 3.13.7:

    cd packages/desktop
    flutter test --no-pub test/lifecycle_test.dart --reporter expanded
    flutter test --no-pub --reporter expanded

All four lifecycle checks and all 40 desktop tests pass. The dismissal regression
observes the hint before expiry and partway through the fade, then confirms its
removal; a real button beneath it receives the dismissing click. Existing checks
cover both keyboard combinations, retained focus/draft, repeat suppression, and
awaited shutdown. From the repository root, `dart analyze packages/desktop` and
`git diff --check` pass. MCP hot reload succeeds with no fresh runtime errors.
No formatter was run. The shorter confirmation interval is deliberate; native
Windows appearance and screen-reader announcements were not exercised.

## 2026-10-31 — Codex-style MCP result and output boundaries

User decision: follow Codex when large MCP results are consumed through Code
Mode. Remove the manager's 64 KiB replacement error: JavaScript receives the
complete MCP envelope so it can parse and filter data before printing. Preserve
`content`, `structuredContent`, and `isError`; exclude client-private top-level
`_meta` before exposing results to the agent or recording nested host output.
An ordinary MCP error remains an envelope that the cell must check before
parsing its text. The shared agent guidance now makes that check explicit.

Keep output presentation separate. Cells retain their existing 10,000 approximate
token default, pragma override, UTF-8 head/tail truncation, and bounded output
collector. Direct MCP calls use the same text formatter at the model-history
boundary with a 10,000-token budget. Their success/error flag is independent of
truncated text; small results retain the existing JSON wrapper. Both providers
use this shared agent path. Full nested MCP data remains in durable host history,
outside the printed cell response.

Use a separate 64 MiB ceiling for each MCP stdio message, HTTP JSON body, or SSE
event, aligned with Codex's Code Mode host-frame ceiling. Exceeding that bound
fails the transport instead of fabricating a tool-content error. General protocol
and MCP catalog bounds are unchanged. This selects Codex's separation of raw
results and model presentation, not its complete MCP or Code Mode implementation.

Source evidence: the user-selected local Codex checkout at
`67f0994b532b8740f14b5b738af7b7b2a915b1d6`. Inspected
`codex-rs/core/src/tools/context.rs` (`McpToolOutput::code_mode_result` and
`response_payload`), `codex-rs/tools/src/tool_output.rs` (MCP serialization without
private metadata), and `codex-rs/code-mode-protocol/src/host/codec.rs` (64 MiB
frame bound). The raw-result/history separation in `context.rs` is also present
at the previously pinned `a795f961be68383738e56ac396742b3e8451696a`. Reproduce
source reads with `git show REVISION:PATH` in that checkout.

Evidence and reproduction on macOS arm64, Dart 3.13.7, Flutter 3.47.8:

    dart test test/server_tools_test.dart test/mcp_test.dart test/code_mode_test.dart -r expanded
    dart test -r expanded
    dart analyze
    git diff --check

The new server regression failed before the repair because the cell could not
retrieve or filter its oversized result and saved no values. It now parses a
3 MiB reply from a real supervised subprocess, selects a library at the end of
the payload, and persists completion. Other assertions cover bounded printing,
bounded direct successes and errors, structured data, and private metadata.
The HTTP fixture preserves 4 MiB of UTF-8 text through both JSON and SSE. The
full repository suite passes all 74 tests and analysis reports no issues.

Official MCP hot reload succeeded in the existing desktop session with no
runtime errors. The original live `getIsolate` call then returned 299,180 text
characters containing 2,256 libraries, and in-cell filtering selected
`package:desktop/app.dart`. No authentication URIs are retained in this record.

Tradeoffs and remaining limits: retaining complete replies increases copying and
history size. QuickJS's existing 32 MiB memory, CPU, timeout, and store limits
still apply; accepting a transport message does not guarantee that a cell can
process it. The 64 MiB boundary was not load-tested, and this evidence does not
establish cross-platform capacity or all of Codex's model-specific output policy.

## 2026-10-31 — Shared composer popover and MCP inventory

User requirement: follow `/Users/meoyawn/Developer/harness/client` for `/mcp`,
also implement `/mcp verbose`, and use the existing file-search popover for all
composer autocomplete. `ComposerAutocomplete` in `file_autocomplete.dart` now
owns one overlay, anchor, scroll controller, selection index, and keyboard path
for file mentions, slash suggestions, and MCP status. `McpStatusMenu` supplies
only content inside that surface. Neither command creates a task, invokes the
model, writes history, changes config, or calls an MCP tool. Commands also work
before provider sign-in and while a task is working.

Selecting a command removes only its query and opens a transient filter scope;
surrounding text, suffixes, file-reference identities and focus survive. Server
rows are read-only Enabled/Disabled and authentication information. Verbose adds
connection state, tool names, resources and resource templates. Escape, blur,
navigation, a new mention/command, or accepted submission retires the scope.
IME composition is left alone. A selected whole-command paste is recognized
when submitted instead of becoming a prompt. The surface keeps the file menu's
320-pixel height cap and does not move the composer or transcript.

The network owner exposes `mcp.inventory`, with optional `verbose` and `server`
parameters. The manager retains accepted configured entries separately from
active connections so disabled servers appear without being launched. Status
and tool names come from the shared runtime. A fresh inventory uses the existing
serialized config reconciliation; invalid edits retain the last accepted config
and return its sanitized diagnostic. Resource catalogs follow existing bounded
pagination. Individual resource/template failures preserve other catalog data.
The existing `mcp.status` response remains unchanged.

Inventory includes display fields only, excluding credentials, command arguments,
endpoint URLs, tool schemas and private metadata. `configured_headers` describes
configuration presence, not successful authentication; HTTP 401/403 reports
`not_authenticated`. Other connections report unsupported interactive auth.
OAuth login is not advertised. Results retain the 2 MiB protocol bound and can
be filtered to a server. Each request has a 30-second server deadline; the client
uses 35 seconds. Closing/superseding a popover sends `mcp.inventory.cancel` with
its request ID, releasing its outstanding MCP requests without stopping shared
processes or unrelated WebSocket work.

Source evidence, inspected using `git show REVISION:PATH` and `rg`:

- Harness client `6b595ec8a160d7d0c0b5dae0a7352793944fe1d5`:
  `lib/ui/chat_view.dart`, `lib/ui/mcp_status_menu.dart`,
  `lib/services/mcp_status_catalog.dart`, and `docs/mcp-status-reference.md`.
  The reference opens a composer submenu with disabled informational rows and
  preserves the draft; its host/thread config cache is not copied because
  Happen currently has one shared global MCP owner.
- Codex `67f0994b532b8740f14b5b738af7b7b2a915b1d6`:
  `codex-rs/tui/src/chatwidget/slash_dispatch.rs`,
  `codex-rs/tui/src/history_cell/mcp.rs`, and
  `codex-rs/app-server-protocol/src/protocol/v2/mcp.rs` establish compact status,
  verbose tool/resource/template inventory, and server-owned discovery. This
  does not add Codex's OAuth or per-thread MCP configuration features.

Verification on macOS arm64, Dart 3.13.7, Flutter 3.47.8:

    dart test test/mcp_inventory_test.dart test/mcp_test.dart test/config_reload_test.dart -r expanded
    flutter test --no-pub packages/desktop/test/view_test.dart -r expanded
    flutter test --no-pub packages/desktop/test -r expanded
    ulimit -n 4096; dart test -r expanded
    dart analyze
    git diff --check

The nine focused server tests pass. New inventory checks use actual UDS, HTTP,
and stdio transports to verify disabled entries, pagination, sanitized partial
failures, preserved process identity, invalid config, overlapping requests, and
underlying request cancellation. The full desktop suite passes 43 tests; the
full repository suite passes 84 tests with the per-shell descriptor limit above.
The initial concurrent full run exhausted its open-file limit during the
existing 100-task streaming case and config reload cases. Raising that limit
for the test process resolved all three failures. Analysis reports no issues.

The live development app initially returned `Unknown MCP operation`: hot reload
did not re-enter the suspended network owner's request handler. A hot restart
loaded the new operation; temporary VM tooling preserved drafts, inline file
references, and the selected project/task. A syntax error in the concurrently
edited DeepSeek page parser initially blocked that restart; its if-case guard
was corrected without changing parsing behavior. Live compact and verbose
discovery then returned the configured servers. No credentials or VM authentication URIs are
retained here.

A live hover also exposed Flutter's nested-tooltip layout assertion beneath a
`CompositedTransformFollower`. The composer regression reproduced it before
the repair and passes afterward. Informational server rows no longer create a
second tooltip overlay. Final hot reload and runtime-error inspection succeed.
These are local functional checks, not cross-platform or long-running-load
measurements. Adding new handlers to an already suspended network entrypoint
still requires restarting that development owner.

## 2026-10-31 — Server-owned repository instructions and multi-turn context

User requirement: implement repository AGENTS.md handling in packages/server
like the inspected Codex checkout, and test context pollution across turns beyond
instruction messages. Move repository discovery to the shared server network
owner. Its per-task snapshot survives the short-lived agent and SQLite owners.
Reuse it while cwd is unchanged; a cwd change discards the previous selection
before discovery. Server restart, archive/restore and a new task/fork/import
start with fresh discovery. File edits alone do not invalidate a warm snapshot.

Keep at most 256 lightweight snapshots in LRU order, independently of resident
task owners; eviction makes the next use a cold resume. This bounded cache is a
Happen lifetime adaptation, not Codex's persistent runtime allocation policy.
Happen has one local filesystem context and no project trust/sandbox selections.
The fixed supported filenames are AGENTS.override.md and AGENTS.md; no additional
configuration knobs or fallback filenames are advertised by this change.

Discovery follows the nearest .git file/directory down to cwd, or cwd alone when
there is no marker. Choose one file per directory; an empty project override
suppresses the regular file. Follow instruction-file symlinks, preserve the
selected cwd's path spelling, and decode UTF-8 lossily within one 32 KiB project
byte budget. Keep the existing independent global bound and nested-file agent
guidance. Reads are asynchronous and bounded; cancellation closes the file
stream and prevents subsequent discovery stages. Global instruction loading
retains its existing per-turn behavior; this change selects repository caching.

Persist the combined snapshot with its context updates as before. Append a
user-role INSTRUCTIONS message only for an applicable nonempty snapshot or an
actual removal. Use Codex's explicit replacement/removal notices. An unchanged
snapshot or an initially empty chain adds nothing. Compaction restores one
current nonempty snapshot; earlier snapshots and notices remain only in durable
history after installation. Restore the initial environment once and update it
only on cwd changes. Do not replace the frozen model instructions/tool prefix.

The broader context audit found an empty MCP availability notice on a fresh task
and unconditional empty MCP/client notices after compaction. Omit these empty
baselines; keep meaningful additions, changes and removal notices. Empty MCP
snapshots can remain local until there is a model-visible update, avoiding an
otherwise unnecessary durable event. Shared history projection already excludes
turn status, nested host-tool records and cell store values; it appends each model
call/result once. The new regression verifies these boundaries through actual
provider requests instead of asserting the context builder's private helpers.

The user explicitly selected Codex's context-saving behavior for the broader
audit too. Match WorldStateHash's sorted-JSON-object comparison for tool schemas;
catalog ordering alone must not append another declaration. Match its per-member
tool deltas: availability messages include only added/changed tools and explicit
removed names, and MCP server guidance is sent only when it changes. Rebuild one
full current baseline after compaction. Do not repeat every unchanged tool name
or usage paragraph on each catalog edit. Existing direct/code-mode result budgets
and durable nested-output separation already follow the selected Codex boundary.
Deferred tool search and Responses Lite are not implemented by these changes.

Pinned source evidence: Codex
`67f0994b532b8740f14b5b738af7b7b2a915b1d6`, inspected with
`git show REVISION:PATH` in /Users/meoyawn/Developer/github/codex:

- codex-rs/core/src/agents_md.rs: ancestor selection, filename precedence,
  worktree markers, empty files, lossy UTF-8 and shared project byte budget.
- codex-rs/core/src/agents_md_manager.rs: cached repository selection and separate
  host-instruction refresh. Happen does not implement its trust/environment API.
- codex-rs/core/src/context/world_state/agents_md.rs and
  codex-rs/core/src/context/user_instructions.rs: deduplicated user context,
  INSTRUCTIONS markers, full replacement and explicit removal.
- codex-rs/core/src/context/world_state/mod.rs: WorldStateHash sorts all JSON
  objects; top_level_tools.rs emits changed members and named removals.
  tools.rs skips initially empty namespace summaries and emits deltas;
  apps_instructions.rs and plugins_instructions.rs omit unavailable guidance.
- codex-rs/core/src/compact.rs: rebuild current world state for a replacement
  window before the last retained real user message/summary. The deferred tools'
  separate 4 KiB namespace-summary cap is not applied to Happen's direct schemas.

Verification environment: macOS arm64, Dart 3.13.7. Commands:

    dart test test/agents_md_test.dart test/context_test.dart test/compaction_test.dart test/deepseek_server_test.dart -r expanded
    dart test test/server_tools_test.dart test/client_tools_test.dart -r expanded
    ulimit -n 4096
    dart test -r expanded
    dart analyze
    git diff --check

Before the cache change, the warm-turn regression appended newly edited files on
its next turn. Before empty-notice suppression, the full-context regression
expected environment plus user input and received an extra empty MCP message.
Extended checks cover five real code-mode turns, unchanged
prefixes/tools/instructions, one-time effort changes, nested unprinted receipts,
restart and repeated compaction. The full repository suite passes all 84 tests.
Whole-repository analysis and whitespace checks pass. The final focused run
passes all eleven context/instruction/tool tests after analyzer cleanup. Official
Dart MCP hot reload succeeds in the existing native Happen app, with no fresh
runtime errors. No formatter was run.
The catalog-order regression also failed before canonical comparison: an unchanged
catalog added a declaration and notice (32 items instead of 30). It now verifies
that changing one tool does not repeat its unchanged sibling's name or guidance.
The focused eleven-test run passes, including explicit MCP/client removal names
and both Console provider identities. The 100-task fixture initially exhausted
the shell's 256-file soft limit; with a process-local 4,096-file limit, the same
fixture passes in about one second. No global machine limits were changed.

These are local provider/transport fixtures, not model-quality, cache-hit,
cross-platform, network-filesystem-latency or long-duration capacity measurements.
Automatically loading descendants still relies on the agent following guidance.

## 2026-10-31 — Shared web tool with lab-owned search backends

User decision: preserve the Codex-style tool interface, use OpenAI-hosted search
for GPT, and use OpenCode Console hosted search for DeepSeek to avoid an auxiliary
model request. Cost, rather than search-quality comparisons, is the selection
criterion. This also applies to DeepSeek reached through the OpenCode model route.
MCP servers must come exclusively from global configuration; neither lab embeds
an MCP server, MCP transport, or automatic MCP fallback.

Expose `web.run` directly and `tools.web__run` inside `functions.exec`. Implement
the shared subset `search_query` (`q`, optional `recency`/`domains`), `open`
(`ref_id`, optional `lineno`), `find` (`ref_id`, `pattern`), and `response_length`.
Reject unknown operations and accept one to four operations per invocation.
Keep the existing code-mode and durable conversation contracts. Tool results
append normally, including after restart and compaction; new tasks declare the
web namespace alongside `functions`.

GPT sends the selected model, task ID, commands and bounded visible conversation
tail to the provider-relative `alpha/search` HTTP endpoint. It reuses ChatGPT
credentials and refreshes once after HTTP 401. The tail follows Codex's two-user
message selection, excludes contextual notices and current assistant commentary,
and approximates its 1,000-token assistant bound with 4,000 characters. Search
output is preserved as tool text with its source URLs and references.

DeepSeek sends `{query, providerID: "opencode"}` to Console's `/api/websearch`
with the existing access token and selected organization. OpenCode's response
contains up to eight source records. Domain/date constraints become query hints
and are also applied to the returned sources; recency excludes undated sources.
This can yield fewer results than the upstream search returned. `open` and `find`
use ordinary unauthenticated HTTP GET for source URLs, convert HTML to readable
text with links, and return zero-based numbered lines. They do not execute page
JavaScript or implement PDF/image operations. GPT can additionally use opaque
references returned by its search service.

All I/O stays in the shared network owner and HTTP pool. Each web request has a
60-second deadline and caller-owned cancellation which aborts its request and
releases its input subscription. Responses are bounded to 2 MiB before parsing;
model-facing output is bounded to 64 KiB. Authenticated POST redirects are
rejected; page GETs carry no provider credentials. Errors do not echo remote
error bodies, headers, or authentication tokens. Optional
`providers.deepseek.web_search.endpoint` and
`providers.opencode.web_search.endpoint` override only Console's HTTP endpoint.

Pinned sources inspected on macOS arm64:

- Codex `2681f8cba2831ef72bca2c0672b2e49d5f690745`:
  `codex-rs/codex-api/src/search.rs`, `endpoint/search.rs`, and
  `ext/web-search/src/{schema,history,tool}.rs` define the command names,
  provider-relative endpoint, visible context selection and plain tool output.
- OpenCode `173f6c6dce7db669679625f6af93651ae66f16be`:
  `packages/core/src/plugin/provider/opencode.ts`,
  `packages/schema/src/websearch.ts`, and
  `services/www/src/docs/content/console/websearch.mdx` define Console's request,
  authentication, response and documented $0.01 successful-search charge.
- DeepSeek Harness `ce7073d51254c26cd63b22a60835b8f948deb447`:
  `packages/web/web-search-exa`, `web-search-perplexity`,
  `web-search-deepseek`, and `web-deepseek-api` contain its alternatives. The
  native Search/Fetch API avoids a model turn; Messages search uses one. This
  inspection does not establish a lower cost than the user's selected backend.

Reproduce source inspection with `git show REVISION:PATH` in the corresponding
local checkout. Current OpenAI guidance was also checked at
https://learn.chatgpt.com/docs/web-search and
https://developers.openai.com/api/docs/guides/tools-web-search.

Verification on macOS arm64, Dart 3.13.7, Flutter 3.47.8:

    ulimit -n 4096
    dart test --reporter expanded
    dart analyze
    git diff --check

The current workspace passes all 84 tests and analysis/whitespace checks. The
new owner-boundary cases execute direct and code-mode searches through real
agent/network/storage owners, check domain/date filtering and HTML retrieval,
resume after restart, reject undeclared operations, abort incomplete responses,
bound oversized replies, sanitize provider failures and reuse the HTTP pool.
The first full run exposed an existing client-tool test's fixed tool inventory;
its assertion now checks the actual contract that client tools are appended
rather than inserted in the initial catalog. The 100-task case exceeded this
shell's default 256-file limit; it passes with the process-local limit above.

Live OpenAI search, open and find calls succeeded using the existing login.
The authenticated public Console configuration endpoint returned HTTP 200 but
advertised no hosted-search configuration; `/api/websearch` returned HTTP 404.
Therefore Console search is verified with protocol fixtures, not claimed to be
available for this account. Unavailable access remains an explicit tool error;
no paid integration was enabled and no search MCP is left in global config.

Fourteen existing idle tasks received one append-only tool declaration through
Dart MCP. Their saved initial configurations were checked unchanged. This was a
one-time operational update, with no migration branch or probe script added to
the repository. The requested AGENTS.md rule keeps such work outside the repo.
The native app accepted hot reload. No Dart formatter was run.

## 2026-10-31 — Composer context usage and one send/stop action

User requirement: borrow the Harness client's context circle, include cache hits
in its tooltip, remove the Enter/Shift+Enter footer hint, and use one button for
Send and Stop. Follow-up requirements: combine model and reasoning into one
picker, move it and the circle to the right, and make the circle discoverable in
existing chats. The user prefers archiving old chats over adding migration glue.
Keep sign-in and live-dictation status visible when they provide information
about the current operation.

Use a 16px ring with a 2px stroke, a clockwise progress arc from twelve o'clock,
70% foreground progress and a 16% foreground track for measured usage. Give the
graphic a 28px hover/tap target with a help cursor. Animate changes over 120 ms
with ease-out unless reduced motion is enabled. Show no percentage beside it;
expose the percentage through image semantics and a centered tooltip above the
ring. The tooltip reports used/window tokens, remaining percentage below 50%, and
cache-hit percentages plus cached/total input counts for the latest response and
the conversation. Keep the control visible when usage is missing, with a 32%
foreground empty track and an explicit unavailable label. Unknown usage must
never be presented as measured zero. Available cache counts remain readable even
if the current context usage or limit is unavailable.

Derive this projection from the desktop's existing durable, sequence-keyed
events. Sort the relevant events by sequence so paged history and live events
produce the same result; their existing map identity prevents double counting a
subscription event that also appears in a history page. Read the denominator
from the task's frozen `provider_settings.context_limit`, including configuration
migration events. The numerator is the latest `model.completed` input plus output
tokens, clamped to the limit. Conversation spending is never the ring numerator.
Omit invalid or unavailable counts, and distinguish measured zero from unknown.

Cache totals include valid usage reports from ordinary responses and compaction
requests. Only input tokens are in the cache-rate denominator. A compaction
request measures the old context; the durable event does not expose the resulting
`context_usage` metadata. Show unavailable usage after successful compaction until
a new model response measures the replacement. This avoids guessing its size or
showing the discarded context as current usage. No provider, protocol, storage or
server changes are needed. Reading the existing events during build also handles
tasks that were already mounted before hot reload, without new retained state.

Group circle, combined picker, microphone and primary action on the right, with
the existing dictation Cancel control at the leading edge. The picker shows the
selected model and effort together and opens one menu with Model and Reasoning
Effort sections and selection checkmarks. Existing tasks keep their model locked;
supported effort changes remain available while running. Disabled entries explain
the fixed-task rules. New tasks can choose both from the same menu. Collapse the
picker to an icon at narrow widths. Keep task settings with `DesktopSession`;
this changes presentation without introducing another settings owner.

Follow Harness's content-sensitive action: a running task with an empty draft
shows Stop; text or attachments switch the same control to Steer/Queue according
to the saved delivery mode. Idle tasks show Send, disabled without content.
Recording dictation can still finalize and send from that control. Stop remains
available while connected even after sign-out. Observe the text controller only
for this small action slot so typing updates its action without rebuilding the
whole composer. Existing draft, attachment, focus, and cancellation owners remain.

Source evidence inspected on macOS arm64, Dart 3.13.7, Flutter 3.47.8:

- Harness checkout `6b595ec8a160d7d0c0b5dae0a7352793944fe1d5`, current
  `client/lib/ui/composer_controls.dart` lines 177–291 (SHA-256
  `dcdbc3fba42590028aab3b8c2fc040d60ebec8283890b0358a9635b8e990e40f`),
  and `client/docs/context-window-reference.md`: ring, accessibility, tooltip,
  cache counts and the requested visibility adaptation.
- Current Harness `client/lib/ui/chat_view.dart` lines 3054–3082 (SHA-256
  `9c7dd95795da0645e70a4817665d1e4c9eb5483cf996404bd8f79efd95630a12`):
  content-sensitive Send/Stop and follow-up delivery ownership. These hashes
  identify the inspected working files, including uncommitted Harness changes.
- The same Harness file's `_modelMenu` and composer footer establish the combined
  menu sections, selected-state checkmarks, fixed-task guidance and right-side
  placement. Happen retains its own provider catalog and task-setting rules.
- Happen `packages/ai/lib/src/model.dart` (`ModelUsage`),
  `packages/agent/lib/agent.dart` (`compactContext` and `model.completed`), and
  desktop history/subscription merging establish the existing usage contract.
- Read-only Dart MCP inspection found two loaded existing chats with 32 and 22
  completed responses, normalized cache counts and frozen 272,000-token limits.
  A third task had seven events, no configuration event and no model response.
  The former require no conversion; the latter has no usage to display. Keep
  missing data explicit instead of adding migration or compatibility branches.
  Follow-up inspection found both existing chats ended in `context.compacted`,
  after their last `model.completed`. The initial hide-after-compaction behavior
  explains their missing circle despite intact historical token/cache reports.
  No task data was changed, archived or rewritten during this investigation.

Reproduce from `packages/desktop`, without running a Dart formatter:

    flutter analyze --no-pub lib/app.dart lib/context_usage.dart lib/model_picker.dart test/view_test.dart
    flutter test --no-pub test/view_test.dart test/dictation_test.dart --reporter expanded

Scoped analysis passes, along with all 27 composer and dictation tests. The
context regression originally failed on the missing 40% indicator and reproduced
the 16px-only hover target on this follow-up. It checks the actual hovered
tooltip from outside the painted edge, right-side placement, chronological
history, live updates, duplicate sequences, compaction, zero/full/invalid counts,
explicit unavailable states, retained cache hits, task switching and preserved
draft/focus. The combined-picker regression failed on its missing trigger before
the change, then exercised new-task model/effort choices, preserved draft text,
running GPT effort changes and fixed-task restrictions. The action regression
exercises Send, Stop, Steer, Queue, whitespace and stopping after sign-out. The
existing dictation regression protects its live fallback status while the
requested keyboard hint stays removed.

Official Dart MCP hot reload succeeded. Read-only inspection of the mounted view
found the 16px painted ring inside its 28px target, followed by one combined
picker, microphone and primary action at the right. The selected existing chat
showed unavailable current usage after compaction while retaining its 95.7%
conversation and 99.9% latest-response cache rates in the tooltip projection.
Draft length, selection and focus were unchanged. Zero error widgets and fresh
runtime errors were reported. Widget tests exercised hovered tooltips and menus
without opening an overlay or submitting input in the live app. Other operating
systems and production AOT rendering performance remain unmeasured.

## 2026-10-31 — One OpenAI web schema for every provider

User requirement: retain one tool interface for every model and provider. Keep
`web.run` and `tools.web__run`; do not introduce provider-specific aliases or
parameter schemas. This supersedes the earlier narrowed three-operation schema.
Authentication, HTTP routes and native API encoding remain lab-owned.

The desktop's HTTP 400 was reproduced with a minimal `gpt-6.1-sol`, low-effort
request. OpenAI returned `invalid_request_error`, parameter `tools`, identifying
`web.run` as reserved and requiring its configured schema. This happens even
when the prompt does not use tools. Adding `strict: false` to the former schema
does not resolve it. The pinned complete baseline schema returns HTTP 200.

Copy the serialized baseline schema into the shared `ai` package without
compacting descriptions, adding constraints or removing operations. Use Codex's
`commands_schema(false)` baseline, excluding its optional literature extension,
uniformly across models. GPT serializes JSON functions with `strict: false`, as
upstream does. Shared validation reads this same schema for types, required
fields, enums and unsigned numbers. The former four-operation/36,500-day limits
and nonempty-string additions no longer apply.

GPT forwards all baseline operations to OpenAI search. Console retains its
implemented search/open/find backend and explicitly rejects unavailable
operations with `web_search_unsupported`. The shared instructions explain this
possibility. A common interface does not establish identical hosted-service
capabilities; no automatic backend fallback was added.

Pinned evidence: Codex `2681f8cba2831ef72bca2c0672b2e49d5f690745`,
`codex-rs/codex-api/src/search.rs`, `ext/web-search/src/{schema,tool}.rs`,
`tools/src/responses_api.rs`, and
`core/tests/suite/snapshots/all__suite__scenarios__web_search__literature_search_web_run_schema.snap`.
Reproduce with `git show REVISION:PATH` in `/Users/meoyawn/Developer/github/codex`.
Removing only `literature_search_query` from the snapshot and hashing sorted,
compact JSON yields SHA-256
`de3be87e7abfe9b67ba757f27804d4206b51c2a8de9e9799fa7db9ef4abe3539`.
The server regression rejects any other schema at the real request boundary for
both GPT and Console, reproducing the original failed turn before the fix.

Verification: macOS arm64, Dart 3.13.7, Flutter 3.47.8. Commands:

    ulimit -n 4096
    dart test --reporter expanded
    dart test test/web_search_test.dart --reporter expanded
    dart analyze
    cd packages/desktop
    flutter test --no-pub --reporter expanded
    git diff --check

All 84 repository tests and all 45 desktop tests pass. Analysis and whitespace
checks pass. Temporary provider probes using the desktop credential owner
completed the Ray Peat research question over HTTP/SSE and WebSocket; each
executed two web calls and returned a final answer with source links. Dart MCP
hot reload succeeded and no runtime errors were found. Sanitized measurements
are in [web schema evidence](evidence/web-tool-schema.json).

Fifteen saved idle tasks retained the old schema: one initial declaration and
fourteen appended declarations, across GPT and DeepSeek. A one-time Dart MCP
operation used the running server's writer ownership to append corrected
configuration records. For fourteen active contexts with old declarations, it
appended a replacement context containing the same conversation and corrected
tool declarations. Original history was retained; no model summary or in-place
history rewrite was used. This intentionally creates a cache boundary for the
invalid schema. Reinspection found zero outdated active declarations. No
operational script or special migration branch was added to the repository.

Live acceptance is verified for `gpt-6.1-sol`; other hosted model/account
availability and specialized Console operations remain unverified.

## 2026-10-31 — Code-mode storage accepts large JSON results

The reported `getIsolate` cell parsed a complete MCP response but failed when
`store("mainIsolate", value)` hit a hardcoded 262,144-character JSON limit.
An independent 1,048,576-character limit on the whole store would reject larger
values after assignment. These checks belong to `packages/code_mode`, not the
agent's persistence or model-output boundary.

Remove both serialized-size checks. Preserve JSON validation and snapshotting,
fresh cell contexts, and the existing QuickJS memory, CPU and wall-time limits.
The agent continues to commit explicit values with task metadata and history,
while sending only printed output to the model. No agent interface, storage
format, configuration knob or saved-task migration is needed.

Pinned source evidence: Codex `67f0994b532b8740f14b5b738af7b7b2a915b1d6`,
`codex-rs/code-mode-runtime/src/runtime/callbacks.rs` (`store_callback` and
`load_callback`) converts values to JSON without per-value or aggregate size
checks; `session_runtime/mod.rs` carries explicit values between cells and
commits writes at completion. `code-mode-protocol/src/description.rs` advertises
serializable values without these extra limits. Reproduce source reads with
`git show REVISION:PATH` in `/Users/meoyawn/Developer/github/codex`.

Verification on macOS arm64, Dart 3.13.7:

    dart test test/code_mode_test.dart --plain-name 'large JSON values survive store and load across fresh cells' --reporter expanded
    dart test test/code_mode_test.dart test/server_tools_test.dart test/context/bloat_test.dart --reporter expanded
    ulimit -n 4096
    dart test --reporter expanded
    dart analyze
    git diff --check

The regression first failed with `Stored value too large`, then with
`Cell store limit exceeded` after removing only the per-value check. It passes
after both checks are removed: parallel host replies include a JSON result over
3 MiB, the stored snapshot survives mutation of the original, and a fresh cell
loads and verifies its full contents while printing only a selected summary.
All 12 focused tests and all 88 repository tests pass. Scoped analysis of
`packages/code_mode` and `test/code_mode_test.dart` reports no issues; full
analysis reports only an informational `use_null_aware_elements` lint in the
unrelated `test/context/discovery_test.dart:21`. Whitespace checks pass.
No Dart formatter was run.

Official Dart MCP hot reload succeeded with no runtime errors. A fresh live
`getIsolate` response contained 298,125 text characters and 2,284 libraries.
An ad hoc VM evaluation passed that response through the reloaded `CodeMode`,
stored the complete parsed object, then loaded it in a second fresh cell and
selected `package:desktop/app.dart`. Only the summary was inspected; no saved
task was changed and no operational probe was added to the repository.

Tradeoff: larger saved state costs memory, copying and durable history space;
the complete store is still loaded into each fresh cell. Removing these two
caps does not promise unlimited storage or that every accepted MCP transport
message fits the default 32 MiB runtime. The regression establishes this tested
3 MiB case, not maximum capacity or parity with Codex's V8 memory management.

## 2026-10-31 — Deferred tool discovery and conditional catalog refresh

User decision: implement the recommended deferred discovery design, keep each
change in its owning layer, and group the important context-bloat regressions
under `test/context/`. The user also asked whether refreshing tools is necessary
when code mode can discover them later.

After comparing OpenCode-style discovery, the user reaffirmed following the local
Codex checkout. `git -C /Users/meoyawn/Developer/github/codex rev-parse HEAD`
still reports the pinned revision below. Its search spec accepts `query` and
`limit`; its handler returns declarations for code-mode calls and native tool
definitions for direct calls. Happen already implements this separation. Keep
both paths and the existing search interface. Native loading retains its schema
lifecycle cost in exchange for direct calls; no task-quality comparison establishes
a benefit from removing it. The documented ranking and result-shape differences
remain; this decision does not claim identical search results or full Codex parity.

Keep catalog change checks, but separate them from schema loading. A model-step
boundary checks revisions so newly available namespaces and changes/removals of
already loaded native tools remain visible. Code-mode cells read the current host
registry when they start; `tools.tool_search` reads it again when invoked. This
also supports a config write followed by discovery inside the same cell.
`ALL_TOOLS` is the cell's starting snapshot. It is not rewritten underneath
running JavaScript; search is the way to observe a later change.

The MCP owner caches catalog snapshots against server tool-map generations and
usage guidance. Unchanged reads return only the revision and an unchanged flag;
reconnection, removal, tool-list replacement, and guidance changes invalidate
the snapshot. Client registrations have their own revisions. The network owner
still performs bounded config reconciliation on MCP catalog reads. Keeping that
read closes the existing race where a tool edits config before the watcher's
200 ms debounce fires. This saves schema rebuilding/copying and avoids context
pollution; it does not claim to eliminate filesystem checks or polling.

New tasks keep `functions.exec`, `web.run`, and `tool_search` eager. MCP and client
schemas remain in the host registry. Automatic notices describe namespaces and
tool counts, with at most 160 UTF-8 bytes of server guidance per namespace and a
4 KiB cap per notice. Full guidance is returned by discovery; changing guidance
past the abbreviated prefix still invalidates earlier guidance explicitly.
Unchanged schemas and changes to unused schemas produce no declarations.

Both discovery paths use the agent's local BM25 selection, with Unicode words,
camel-case splitting, deterministic ties, and exact callable-name priority.
The default limit is 8; Happen caps it at 32. This uses the Codex query/limit
contract, not its English stemmer or an identical ranking implementation.
Code-mode search returns names, TypeScript declarations, original JSON schemas,
and applicable server instructions. Only printed results enter model context.
The declarations are rendered in `packages/code_mode`; original schemas remain
available because TypeScript cannot represent every JSON Schema constraint.

Direct search loads only selected native definitions. The shared AI record uses
the `search` tool format with JSON arguments and attaches selected definitions to
its correlated result. `packages/gpt` maps these to client-executed
`tool_search_call`/`tool_search_output` and marks returned functions deferred.
`packages/deepseek` exposes a JSON search function, supplies selected schemas to
its catalog, and places native Messages tool references after the search result;
the Console/Chat route uses its existing request-level catalog. Provider wire
details stay in their lab packages. Connections, config reconciliation, client
ownership, and actual calls stay in the server/MCP owners.

Repeated native searches do not repeat unchanged schemas. Already loaded schemas
receive append-only updates; removal notices name loaded tools and live routing
rejects stale calls. Compaction restores current namespace summaries and only
the still-available loaded subset. A retained search exchange keeps its result
but its definitions are restored once in the baseline. Code-mode discovery text
follows ordinary history compaction. Older saved tasks gain one ordered search
declaration without rewriting their initial instructions or tools; historical
eager declarations still count as loaded. This supersedes the earlier policy of
eagerly appending and restoring the entire external catalog.

Pinned source evidence: Codex `67f0994b532b8740f14b5b738af7b7b2a915b1d6`,
inspected in `/Users/meoyawn/Developer/github/codex` with `git show REVISION:PATH`:

- `codex-rs/core/src/tools/handlers/tool_search.rs` and `tool_search_spec.rs`:
  local BM25, query/limit arguments, code-mode versus direct search behavior.
- `codex-rs/protocol/src/models.rs`: client execution, call IDs, arguments,
  selected tools and deferred-loading fields in the native search wire records.
- `codex-rs/core/src/context/world_state/tools.rs` and
  `top_level_tools.rs`: bounded deferred namespace context and loaded-tool deltas.
- [OpenAI tool-search documentation](https://developers.openai.com/api/docs/guides/tools-tool-search):
  client-executed loading and preserving the earlier prompt prefix.

Verification on macOS arm64, Dart 3.13.7, in the working tree based on
`9470b12e3d40b8b86e42b60f1f9400ed9748a648`:

    dart test test/context test/server_tools_test.dart test/client_tools_test.dart test/mcp_test.dart -r expanded
    dart test test/deepseek_test.dart test/deepseek_server_test.dart -r expanded
    ulimit -n 4096
    dart test -r expanded
    dart analyze
    git diff --check
    dart run tool/verify_mcp_tools.dart

The new context regression first failed because 241 external schemas entered the
initial request. It now verifies bounded initial context, fresh discovery after
an in-cell config/guidance change, code-mode execution without native loading,
single-tool native loading, repeated-search deduplication, offline changes,
restart, repeated compaction, and resuming a saved pre-discovery configuration.
The relocated bloat, instruction, and compaction tests retain their prefix,
deduplication, recall, cancellation, and transfer checks. Existing MCP/client
lifecycle tests now perform discovery before direct calls. DeepSeek checks cover
native Messages selection/result ordering and both Console provider identities.

The full suite passes 88 tests in the concurrent checkout. Analysis and whitespace checks pass; no Dart
formatter was run. Live `gpt-6.1-sol` at low effort passed both native and code-mode
discovery over HTTP and WebSocket, using real supervised Dart MCP and probe
processes. [Sanitized evidence](evidence/deferred-tools-live.json) records checks,
elapsed time and usage. Only the selected probe became a native declaration;
code-mode lookup executed it without loading native schemas.

Limits: these live runs establish GPT wire acceptance and functional execution,
not a model-quality or cache-efficiency comparison. DeepSeek evidence for this
change is local protocol/server fixtures. Search still costs a discovery step
for unfamiliar tools; BM25 does not provide semantic synonym matching. Full
catalog metadata remains in host memory, and a count-limited search result may
still contain large individual schemas. No user tasks were migrated or edited.

## 2026-10-31 — Recover missing context limits in cached desktop tasks

The reported circle had response token counts but no denominator. Read-only
Dart MCP inspection found five loaded desktop caches missing sequence 1. The
selected task's first `history.page` record was `task.created` with a frozen
272,000-token limit. Its durable configuration was intact; the in-memory cache
had missed admission and `loaded = true` prevented later history retrieval.
Earlier server broadcasts forwarded raw store events without an outer `task_id`
(`9470b12`, `packages/server/lib/server.dart`, `_broadcast`). The existing identity
fix in `c3c5180` routes new events correctly but cannot restore missed events.

On selection, replay a nonempty cached transcript whose initial sequence is
missing, using the existing subscribe-before-paging and sequence-keyed merge.
Keep complete cached transcripts on their existing fast path. Use the task's
stored settings, without substituting a current catalog default or rewriting
history. The server also broadcasts its committed `task.configuration_migrated`
event: previously this path persisted the resolved limit without notifying
already subscribed clients. The event shape and frozen-setting contract stay
unchanged. No new settings owner or operational migration is introduced.

The desktop regression removes the admission event from a real streamed task,
then reselects it. Before the fix the limit remained null; afterward the same
event ID and frozen limit return without duplicate usage, draft loss, or loss of
an unsent reasoning selection. The server regression resumes a stored legacy
configuration through the real WebSocket route. Before the fix no configuration
notification arrived; afterward its task identity and settings match history.
These extend the existing lifecycle and notification tests; the existing widget
test owns the ring, tooltip, replay, cache totals, and unknown-usage behavior.

Verification on macOS arm64, Dart 3.13.7, Flutter 3.47.8:

    cd packages/desktop
    flutter test --no-pub test/session_test.dart test/view_test.dart --reporter expanded
    cd ../..
    dart test test/server_test.dart --reporter expanded
    ulimit -n 4096
    dart test test/server_test.dart --plain-name 'one socket searches files while 100 tasks stream, and cancels one task independently' --reporter expanded
    dart analyze packages/desktop/lib/session.dart packages/desktop/test/session_test.dart packages/server/lib/server.dart test/server_test.dart
    git diff --check

All 19 desktop checks and eight server checks pass. The 100-task server case
initially timed out with the shell's 256-file limit and passed with 4,096, as
required by the earlier verification instructions. Scoped analysis and whitespace
checks pass. No Dart formatter was run.

Hot reload succeeded. Replaying the five incomplete in-memory caches through
`DesktopSession.loadHistory` recovered their initial events with no load errors.
No stored task data was changed. The mounted ring painter reports 45.56%, its
semantics reports 46%, and its tooltip shows 124k / 272k tokens with 93.6%
conversation and 99.1% latest-response cache hits. Selection and drafts remained
unchanged, and Dart MCP reported no runtime errors.

Tradeoff: an incomplete cache requires a history replay on selection. This
targets missing admission, not arbitrary missing events in an otherwise complete
cache. Compaction still leaves usage explicitly unknown until a model response
measures the replacement context; no new size estimate is presented as measured.

## 2026-10-31 — Steering preempts in-flight inference

User requirement: repair slow steering in `packages/agent` and follow the local
Codex checkout. Previously, accepted input waited for the complete provider
response, which could leave a correction pending throughout long reasoning.
Supersede the earlier next-model-boundary delivery policy for in-flight inference.

Give each ordinary model request a fresh cancellation token linked to its turn.
Steering queues the input and cancels only that request. The existing isolate RPC
cancellation forwards its operation ID to the network owner, releasing the owned
provider request without cancelling tools, other requests, or the shared pool.
Resume the same turn, committing steering and its effort update in their existing
atomic batch before sampling again. Cancellation caused by Stop still ends the
turn; genuine provider failures keep their existing failure/recovery paths.
Recheck pending steering before starting inference so arrivals during catalog
refresh or automatic compaction do not start another request with stale input.
Ignore stream events after cancellation. Desktop clears abandoned partial text
and reconnecting state when the steered input is committed.

Pinned evidence: Codex `67f0994b532b8740f14b5b738af7b7b2a915b1d6`, inspected
in `/Users/meoyawn/Developer/github/codex`:

- `codex-rs/features/src/lib.rs`: `instant_interrupt` is enabled by default.
- `codex-rs/core/src/session/mod.rs` and `step_context.rs`: each sampling step
  owns a separate preemption token.
- `codex-rs/core/src/session/input_queue.rs`: `watch_user_input` subscribes
  before checking already pending user input and signals that token.
- `codex-rs/core/src/session/turn.rs`: stream reads and retry waits observe
  preemption separately from turn cancellation, then continue the same turn with
  queued input; already dispatched native tools settle before continuation.
- `codex-rs/core/tests/suite/pending_input.rs`: the preemption regression keeps
  the original stream gated until the replacement request arrives.

Reproduce source inspection with `git show REVISION:PATH` in that checkout.
Verification environment: macOS arm64, Dart 3.13.7, Flutter 3.47.8.

    dart test test/server_test.dart --plain-name 'steering preempts inference' --reporter expanded
    cd packages/desktop
    flutter test --no-pub test/session_test.dart --plain-name 'streams nested code-mode calls' --reporter expanded

The server regression first failed with `Steering did not advance the active
turn`. It now passes two successive interruptions with both original streams
still blocked, completed tool state preserved, no stale-input retries, ordered
effort/input updates, and the queued message starting its own later turn. The
desktop regression independently reproduced abandoned `Hello` text after steering
was committed and passes after clearing that projection. It exercises the existing
real UDS session, receipt timestamps, effort selection and restart behavior.

Full verification from the repository root:

    ulimit -n 4096
    dart test --reporter expanded
    dart analyze
    cd packages/desktop
    flutter test --no-pub --reporter expanded
    cd ../..
    git diff --check

All 89 repository tests and all 45 desktop tests pass. Analysis and whitespace
checks pass. Official Dart MCP hot reload succeeds in the native app, with no
runtime errors before or after reload. No Dart formatter was run. These are local
provider fixtures, not live-model latency measurements. Suspended async turn
bodies are not replaced by hot reload; an already running turn adopts the new
loop on its next turn invocation.

Limits: this adopts Codex's ordinary inference preemption, not its Responses Lite
drain protocol or yielded code-mode runtime. Running tools and automatic
compaction retain their existing cancellation owners and settle before steering
is committed. Happen still commits model output at response completion; abandoned
partial output and unreported provider usage are not durable conversation data.
Repeated steering can therefore discard inference work. No provider wire format,
tool capability, task-history schema, or one-time operational repair was added.

## 2026-10-31 — Subscription accounts and one composer model list

User requirement: remove the desktop's default-provider setting and DeepSeek
API-key account, keep ChatGPT and OpenCode subscriptions, and concatenate their
model lists in the composer. This replaces the provider-setting and native
DeepSeek discovery choices in the earlier thin-desktop decision.

`providers.list` now advertises only `gpt` and `opencode`. The desktop also
filters discovery to those identities, including responses from an already
running network owner with the previous catalog. Model entries carry their
provider identity in the desktop projection. Choosing a model selects that
provider, its authentication status, and its default reasoning; later account
refreshes preserve the chosen model and effort. The picker lists both complete
implemented catalogs regardless of the selected account or its login status.
Existing tasks retain their fixed provider/model and reasoning-update rules.

Remove the saved desktop-provider read/write path. Initial desktop selection
uses the first subscription's configured default model, independent of an old
desktop provider setting or the CLI's global `default_provider`. No stored
settings or task data are rewritten. Native/legacy server routing and the
reusable DeepSeek adapter remain available to existing CLI/API callers; their
removal is outside this desktop account change.

Catalog scope remains five implemented GPT models and OpenCode's exact
`deepseek-v4.1-flash-free` route. Consulted the vendored Codex catalog at
`2681f8cba2831ef72bca2c0672b2e49d5f690745` and OpenCode
`fa96f42f6cd8bf21f11fd5b38d78e2dd34d5563e`'s
`packages/core/src/plugin/provider/opencode.ts` and
`packages/core/src/models-dev/snapshot.txt` with `git show REVISION:PATH` in
`/Users/meoyawn/Developer/github/opencode`. The latter confirms the free model's
200,000-token context, 32,000-token output and fixed effort. Concatenating the
implemented catalogs does not enable additional upstream model routes or change
authentication/inference contracts.

Verification on macOS arm64, Dart 3.13.7, Flutter 3.47.8:

    cd packages/desktop
    flutter test --no-pub test --reporter expanded
    cd ../..
    ulimit -n 4096
    dart test --reporter expanded
    dart analyze
    git diff --check

The widget regression switches from a signed-in GPT model to a signed-out
OpenCode model and back, checks provider-specific effort choices and account
refreshes, retains the draft, and keeps both models locked in existing tasks.
It also supplies an older three-provider response and confirms native DeepSeek
is absent. Settings checks cover the two accounts and removed default selector.
A real WebSocket/server regression starts tasks through both local HTTP provider
fixtures and checks their exact model, endpoint, reasoning and rendered reply;
an obsolete saved native-provider preference does not affect selection.
All 89 repository tests and 46 desktop tests pass. Whole-repository analysis and
whitespace checks pass.

Official Dart MCP hot reload and a provider refresh applied the change in the
running desktop. Read-only VM inspection found exactly two accounts and six
models, the original selected GPT model, and both active tasks still running.
No runtime errors were reported. These checks establish local routing and UI
behavior; subscription entitlements and new live-model inference were not
retested. No Dart formatter was run.
