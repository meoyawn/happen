# Deterministic Codex context contract

```sh
moon run test-e2e
```

This is a source-level integration contract, not a model-quality eval or a CLI
startup test. Happen runs its production agent and provider in-process through
`AgentServer.startLocal`. The installed Codex executable is the independent
reference. Neither a compiled Happen CLI nor a CLI build dependency is needed.
The models and scenarios are a named, parameterized Dart test matrix; the Moon
command takes no scenario/model overrides. `test-unit` excludes the `e2e` tag
and also runs from source. The separate `build-cli` task remains cached for release
builds and is not a dependency of this comparison.

The fixed target launches the Dart tests through `tool/test_e2e.dart` with an
empty temporary home and a minimal environment. This also isolates Happen's real
shell/MCP children from the caller's startup files and credentials. Direct
unisolated invocation of this test file is rejected. Each pair's Dart MCP
processes additionally receive the same explicit fixture environment.
The real `dart mcp-server --help` command prepares the SDK's server package once
before either harness starts. Functional replays use real production
connections; no discovery response or tool result is substituted. Happen's
in-process server retains its production shared MCP owner between fresh threads;
Codex starts its own processes for each CLI invocation.
Happen unloads the thread between replayed user turns to match that cold resume.
The launcher invokes package:test from source after normal native-hook setup;
it does not run dependency resolution under the temporary home or rewrite the
workspace's package configuration with temporary cache paths.

## Isolation and real execution

The matrix uses the catalog-selected default model (`gpt-6.1-sol`), Sol with an
explicit `xhigh` selection, and Terra with its catalog reasoning default. Every
selection runs with tool search enabled. `packages/openai` always includes it
when deferred tools are available; it is not a config setting. The reference
explicitly enables `code_mode_tool_search` to match. The unchanged
`packages/openai/catalog/models.json` selects no reasoning
summary, low verbosity, Code Mode only, and Responses Lite. The evidence includes
the catalog's original bytes and SHA-256. The default-model branch omits model
and effort overrides in both harnesses; other branches select only the named
model or effort.
Each pair uses separate empty data/credential homes, real instruction and skill
files, and explicitly isolated tool settings. Requests carry tool declarations
and base instructions in a durable history prefix, omit top-level `tools` and
`instructions`, set `parallel_tool_calls: false`, and use
`reasoning.context: "all_turns"`, matching Codex's Responses Lite client.
Codex's bundled skills, plugins, apps, collaboration and permission prompts are
disabled explicitly. Content classifications and source attribution remain
enabled and are compared strictly; generated turn/time metadata is normalized
with the other scoped IDs. Shell snapshots, MCP credential storage, optional
startup grace, server optionality and tool approval use Codex's defaults.
No user config or ChatGPT account is used. Shell
selection is not overridden: the runtime follows Codex's account-database shell
selection and platform defaults, not the launching terminal's `SHELL` value.
Commands also keep the default login mode, exercising snapshot capture and
restoration in the isolated home.
Shell replays explicitly select a PTY and disable its newline conversion with
`stty -onlcr`. The installed Codex 0.166.0 reference can leave exited pipe
children unreaped and wait indefinitely for their exit notification. PTY
execution avoids that reference defect while retaining real commands, exact
output bytes and exit-status assertions. Happen's default pipe execution is
covered by the tool-runtime and shell-snapshot suites.
Standalone OpenAI web search is enabled in both configurations
(`web_search = "live"`). Codex uses its built-in OpenAI provider with a local
base URL and a synthetic API key. The HTTP-only peer rejects WebSocket upgrades
with 426, exercising Codex's production HTTP fallback. The catalog's Code Mode
only layout exposes search as `tools.web__run` inside `functions.exec`. App usage
instructions remain disabled by the unchanged model catalog.
The reference keeps the current default `sleep_tool` gate and model-driven mode;
the matrix model advertises clock support. Goals are explicitly enabled.

Global skill discovery is explicitly redirected to the same temporary
`home-*/.agents/skills` directory in a randomly named fixture home. Codex receives
that generated `HOME`, and Happen receives the same `skillsHome` through its
production embedding API. The
`global_skills` fixtures populate that directory. Repository `.agents/skills`
fixtures remain separate. Each context must list exactly `catalog_skills`; any
extra user, bundled, or plugin skill fails the isolation assertion.

**OpenAI's Responses and search endpoints are synthetic.** `cases.dart` supplies native output
arrays. The local HTTP peer emits real Responses SSE and advances a scripted
step only after the previous call IDs have actual tool results. Completed output
items arrive through `response.output_item.done`; the terminal completion packet
contains an empty output summary, matching the ChatGPT streaming path. File
operations, JavaScript, SQLite, instruction discovery, skills, tool search, and
MCP execution are real.

The `streamed-continuation` case additionally omits stream indexes and sends
commentary with `end_turn: false`. Neither harness may stop there: both must make
the next inference, actually read the fixture file through the shell, and return
its receipt in the final request. The fixture advances past commentary only when
the next received request retains the commentary item IDs it actually issued.
The web case prompts `google youtube to podcast tools`. Both harnesses must
execute their production standalone-search client against `/alpha/search` with
the specified query and live-access setting. The endpoint supplies a unique
receipt; the next inference must retain it and the cited answer. Captures retain
both search requests and Responses requests. This replay makes no live internet
query. Sleep is exercised directly, including invalid zero
duration; goal tools create, inspect, account usage, complete, and inspect again.

The `fermented-beetroot` case preserves the Russian prompt, all fourteen native
output items, web search/open/find actions, reasoning summaries, and the cited
final answer from `context-21b8348e.json`. The hosted workflow arrives in one
indexless Responses stream without client tool calls. Only model IDs and opaque
encrypted reasoning use fixture identities. A second user turn cold-resumes
both harnesses and requires every emitted item, including the final answer and
all citation metadata, to reach the next actual inference request in order.
No live web requests or personal instructions are used.

The goal case also cold-resumes the completed goal: Codex launches a new CLI
process, and Happen unsubscribes and waits for idle thread unloading before the
next prompt. Goal state uses dedicated tables in the same session SQLite;
host-owned goal accounting survives inference turns and restores on cold resume.
The package-reading MCP case installs the real server through `dart mcp-server`
and starts its installed app-bundle executable directly in each harness. This
keeps command-dispatcher startup outside Codex's default one-second optional
server grace. Both processes use the same Dart SDK, register the fixture package,
and read its package URI. The separate
`dart-evaluation-discovery` case searches the same real catalog with
`+mcp__dart evaluate expression flutter driver runtime errors` and compares the
ordered results and full TypeScript declarations in the catalog's Code Mode
only layout. Both scenarios discover tools through the real ranked search
handler. Native discovery's schema and output-schema omission contracts are
covered separately by `test/openai_mcp_output_test.dart`.
It does not execute the discovered tools, connect to an app, or interact with the
human's desktop. The
broad query does not select `vm_service` among the default eight in either
harness. A second targeted `dart vm_service evaluate expression` query must
return that exact tool in the corresponding result format.

The `tldw-youtube` case is derived from the supplied
`tldw-https-www-youtube-com-watch-v-ebilgcon4uu-b4b0ca13.json` export. It combines
introductory commentary, parallel `Promise.allSettled` shell receipts, hosted
YouTube open/search items, four opaque reasoning items with summaries, and a
truncated transcript read followed by a timestamp-filtered reread. Commentary and
the final reasoning-only step must continue to inference rather than ending the
turn. Its prompt names the isolated `fixture-youtube-transcript` and `fixture-tldw`
skills. Both harnesses must list exactly those two skills and read their complete
`SKILL.md` files through real shell calls before inspecting the transcript.
Skill bodies must stay out of the initial context and reach inference in the
tool receipts. Every emitted model item must survive in order through the eighth
request.
The transcript fixture preserves the export's 14:01–34:58 excerpt byte-for-byte.
Cached-file discovery replaces network transcription, paths are fixture-local,
encrypted reasoning uses distinct sentinels, and the initial shell budget is
lowered to truncate the excerpt without truncating the surrounding JSON receipt.
No YouTube request, Bun script, personal instruction tree, or user MCP is used.
Reasoning without raw content is replayed as `content: null`, matching Codex's
wire encoding rather than omitting the field.

## Assertions and evidence

Only actual requests received by the shared OpenAI endpoint are compared. Every
paired inference request uses deep JSON equality, including the first request,
continuations, tool results, compaction and cold resume. Request counts must
match; an intermediate mismatch cannot be repaired by a later matching context.
The comparison excludes the top-level `client_metadata` telemetry field,
removing explicitly scoped generated protocol/transport IDs and normalizing known
numeric timing fields:
object key order is immaterial; array order, message encodings, field presence,
types and values are strict. No message reshaping or array sorting is permitted.
Method, endpoint path, Accept, Content-Type, OpenAI-Beta and
`x-openai-internal-codex-responses-lite` are compared for every paired request.
Both harnesses must negotiate Lite explicitly. Header sidecars retain these
protocol fields without credentials or identity headers. The package-reading
search fixture includes the exact `tool_search.tool_search_tool` response from
`project-picker-before-new-thread-context-625ed706.json` when Lite negotiation is
missing. It reproduces the failed search instead of letting a body-only contract
pass. The exec description normalizes only the known embedded-engine name,
Happen's two settlement-helper declarations, and its MCP-envelope guidance.
All shared tool declarations and the rest of the description remain strict.
Tool declarations,
printed values, roles, message boundaries, dates, settings, and tool results are
not discarded. Happen deliberately does not send Codex's `client_metadata`;
every case independently asserts its absence in Happen's received requests before
the shared comparison excludes it. Raw captures retain Codex's telemetry unchanged.
Question tools retain Codex's default registration. The `default-mode-user-input`
case verifies that blocking questions return the native unavailable-in-Default
error. The `interactive-user-input` case enables Default-mode availability,
matching desktop sessions in Happen. Its
name, description, schema, registration order, and exclusion from Code Mode's
nested declarations are part of the same strict request comparison. The case
also invokes `request_user_input_async` and retains its immediate accepted
receipt in the next inference without a human reply. Other cases keep the
Default-mode gate disabled in both harnesses. The `parallel-tool-calls` case runs
two real shell commands that wait for each other's receipt file; both must exit
successfully. This catches serialized execution without a performance verdict.
Desktop connection capabilities, resuming sessions created without questions,
and delivering user answers are exercised by
`packages/desktop/test/session_question_test.dart`.
Raw request captures retain the original timing values; verdicts and reports do
not contain elapsed-time comparisons or performance assertions.
Shell IDs and timings inside indexed fulfilled `Promise.allSettled` receipts use
the same validation/normalization as direct shell results; settlement, index, and
all remaining nested fields stay strict.
There is no similarity threshold, judge,
golden copied from Happen, or expected-failure bypass. An unsupported Codex
capability is a real failure to fix or configure consistently, not a passing
approximation.

Both harnesses' HTTP bodies are captured unchanged at the same receiving OpenAI endpoint;
its built-in compaction trace is a logical request, not the full transport body,
so that trace is deliberately not used. The endpoint stores exactly the bytes it
received, not a second serialization of its parsed JSON. Comparison uses those
received bodies, not either harness's debug/export API.
There are no separate
prepared contexts, snapshot-based inference reconstructions, or input-only dumps.

File-I/O scripts deliberately yield their JavaScript cells, and the scripted
model calls `wait` before advancing. Shell calls also await their real terminal
receipts through `write_stdin` when `exec_command` yields a running session.
The shared helper retains the final receipt fields and accumulates output and
token counts. The initial yielded cell, wait call and terminal result all remain
in strict request equality. The dedicated resumable-cell scenario stays
unchanged. Compaction's synthetic usage is reported with the wait call so the
terminal receipt enters history before the checkpoint. Exit status remains part
of strict equality; process-completion scheduling is not a verdict.

Identity normalization has independent gates first: thread IDs must be unique,
monotonically ordered UUIDv7 identifiers; generated item IDs have their Codex
type prefix and UUIDv7 suffix, including the retained tool/base prefix.
IDs actually emitted by the synthetic
upstream are preserved, not regenerated. Six-hex shell chunk IDs and shell
session IDs in `1000..99999` are checked before chunk normalization. Concurrent
public Happen turns also exercise its real ID owner's ordering and reach inference.
The deterministic cell counters are not normalized: the cell fixture requires
IDs `1`, `2`, and `3` to refer to the correct live/completed cells.

The suite also independently checks AGENTS.md selection and overrides,
metadata-only skill discovery, full skill reads, deferred tool discovery,
real MCP results reaching inference, resumed input retention, and real automatic
compaction. The multi-user compaction case uses four actual consecutive turns,
then requires every user message to remain in its original order before the
checkpoint in the following request, as in the user-supplied context export.
Compaction is triggered by synthetic reported token usage; both real
loops must request it, install the synthetic native checkpoint, restore rules
and skills once, and remove the old real shell receipt from visible context.
The resumable-cell case also executes real module syntax, checks unavailable
globals/tools, validates UTC clock output, yields and resumes timers, delivers
notifications, terminates a cell, exits through a `finally` block, and checks the
missing-cell diagnostic after completion. Single-text output encoding and the
notification's name, encoding, and position remain part of exact equality.

Results are written to a new ignored `.local/context-contract/TIMESTAMP/`
directory. It retains both configs, the catalog
checksum, Codex version, the native request files and their paths, the first
differing line, and a JSON report of functional checks. Failures exit
nonzero. These artifacts are the evidence when the strict parity contract is red.

### Current Code Mode boundary

Happen retains QuickJS and evaluates actual ES modules through its native API,
not an async-function approximation. `wait`, incremental observations, timers,
`yield_control`, native uncatchable `exit`, and durable `notify` delivery are
implemented. Unawaited work is cancelled when the module completes. The generic
OpenCode evaluator retains its separate async-function/return contract.

The runtime includes real PTY execution, ordered image/generated-image/audio
output, and the Images API generation/editing service. The matrix model does
not accept audio input, so the recorded-audio case requires Codex's unsupported
audio notice in the original content position, without treating base64 as prose.
The media fixtures inspect
actual request content, never play audio or generate a paid image. Keep any
remaining failures visible: do not add dummy declarations or omit `tools` from
equality to make the gate green.

## Deterministic verdicts

Each case runs both harnesses in each execution order, using fresh threads while
retaining Happen's shared MCP owner. This exercises first use, cache reuse,
thread-ID ordering, and isolation without benchmark warm-ups or sampling.

There are no stopwatches, medians, speed ratios, request-arrival measurements, or
elapsed-time pass/fail gates. Known run-specific timestamps and tool durations
are normalized only for exact request equality. All remaining request fields,
array positions, tool results, lifecycle outcomes, and explicit ID contracts stay
strict. Cancellation and generous safety deadlines prevent hung child processes;
they are not performance criteria. Performance investigations belong in separate
benchmarks, not this functional E2E contract.

The app retains its read-only model-buffer inspector. Neither that snapshot nor
a reconstructed request is used by this contract. The obsolete CLI prepared-input,
context-export, and trace-reducer paths have been removed.
