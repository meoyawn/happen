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
before either harness starts, outside timing. Measured runs use real production
connections; no discovery response or tool result is substituted. Happen's
in-process server retains its production shared MCP owner between sampled tasks;
Codex starts its own processes for each CLI invocation.
The launcher invokes package:test from source after normal native-hook setup;
it does not run dependency resolution under the temporary home or rewrite the
workspace's package configuration with temporary cache paths.

## Isolation and real execution

The model axis is `gpt-6.1-sol` and `gpt-6-sol`. Each pair uses the same base model
catalog, explicitly generated
configs, separate empty data/credential homes, real instruction and skill files,
code-mode-only execution, and Standard Responses. The generated Codex catalog
explicitly sets `use_responses_lite: false`; Happen has no Responses Lite path.
Every captured request must have `parallel_tool_calls: true` and omit
`reasoning.context` (the standard backend currently defaults to `current_turn`).
Codex's bundled skills,
plugins, apps, collaboration, account credential storage, and permission prompts
are disabled explicitly. No user config or ChatGPT account is used. Shell
selection is not overridden: the runtime follows Codex's account-database shell
selection and platform defaults, not the launching terminal's `SHELL` value.
Provider-hosted web search is enabled in both configurations (`web_search = "live"`).
The reference keeps the current default `sleep_tool` gate and model-driven mode;
both matrix models advertise clock support. Goals are explicitly enabled.

Global skill discovery is explicitly redirected to the same temporary
`home-*/.agents/skills` directory in a randomly named fixture home. Codex receives
that generated `HOME`, and Happen receives the same `skillsHome` through its
production embedding API. The
`global_skills` fixtures populate that directory. Repository `.agents/skills`
fixtures remain separate. Each context must list exactly `catalog_skills`; any
extra user, bundled, or plugin skill fails the isolation assertion.

**Only the Responses API is synthetic.** `cases.dart` supplies native output
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
The web case supplies deterministic hosted `web_search_call` results and
URL citations through that same Responses stream, then verifies their retention
in the next actual inference request. It needs no live internet query or a second
fake search implementation. Sleep is exercised directly, including invalid zero
duration; goal tools create, inspect, account usage, complete, and inspect again.
The goal case also cold-resumes the completed goal: Codex launches a new CLI
process, and Happen hibernates its session owners before the next prompt. Goal
state uses generic namespaced KV in the same session SQLite; its rules live in
the agent, with no goal-aware storage API.
The package-reading MCP case starts independent real `dart mcp-server`
processes, registers the fixture package, and reads its package URI. The separate
`dart-evaluation-discovery` case searches the same real catalog with
`+mcp__dart evaluate expression flutter driver runtime errors` and compares the
ordered results and full TypeScript declarations. It does not execute the
discovered tools, connect to an app, or interact with the human's desktop. The
broad query does not select `vm_service` among the default eight in either
harness. A second targeted `dart vm_service evaluate expression` query must
return that exact tool and its declaration.

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

Only actual requests received by the shared OpenAI endpoint are compared. At
the end of each session, the final complete inference request uses deep JSON
equality after excluding the top-level `client_metadata` telemetry field,
removing explicitly scoped generated protocol/transport IDs and extracting known
numeric timing fields:
object key order is immaterial; array order, message encodings, field presence,
types and values are strict. No message reshaping or array sorting is permitted.
Tool declarations,
printed values, roles, message boundaries, dates, settings, and tool results are
not discarded. Happen deliberately does not send Codex's `client_metadata`;
every case independently asserts its absence in Happen's received requests before
the shared comparison excludes it. Raw captures retain Codex's telemetry unchanged.
The `interactive-user-input` case enables Codex's direct `request_user_input`
tool and Default-mode availability, matching desktop sessions in Happen. Its
name, description, schema, registration order, and exclusion from Code Mode's
nested declarations are part of the same strict request comparison. Other cases
keep interactive questions disabled in both harnesses.
Every extracted timing value is retained separately in the report, with its
request path, kind and units.
Shell IDs and timings inside indexed fulfilled `Promise.allSettled` receipts use
the same validation/extraction as direct shell results; settlement, index, and
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

Identity normalization has independent gates first: thread IDs must be unique,
monotonically ordered UUIDv7 identifiers; generated item IDs have their Codex
type prefix and UUIDv7 suffix. The prompt-only base instruction ID must match
Codex's thread-scoped UUIDv5 derivation. IDs actually emitted by the synthetic
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
differing line, individual timing samples, and a JSON report. Failures exit
nonzero. These artifacts are the evidence when the strict parity contract is red.

### Current Code Mode boundary

Happen retains QuickJS and evaluates actual ES modules through its native API,
not an async-function approximation. `wait`, incremental observations, timers,
`yield_control`, native uncatchable `exit`, and durable `notify` delivery are
implemented. Unawaited work is cancelled when the module completes. The generic
OpenCode evaluator retains its separate async-function/return contract.

The runtime includes real PTY execution, ordered image/generated-image/audio
output, and the Images API generation/editing service. The two matrix models do
not accept audio input, so the recorded-audio case requires Codex's unsupported
audio notice in the original content position, without treating base64 as prose.
The media fixtures inspect
actual request content, never play audio or generate a paid image. Keep any
remaining failures visible: do not add dummy declarations or omit `tools` from
equality to make the gate green.

## Timing gates

Actual sessions have one warm-up followed by three samples with alternating
execution order. Happen's in-process session median must not exceed Codex's CLI
`exec`/`resume` median. The report labels those different measurement boundaries
explicitly; this is not a CLI-startup benchmark or a preparation-only call.

For real tool and compaction workflows, three runs alternate harness order. The
peer separately measures both real loops from the first model request through
the final synthetic SSE of the last turn. Prelude turns in the multi-user case
do not replace this real tool/compaction measurement with stub-only timing.
Happen's median must not exceed Codex's at that shared
boundary either. A one-response/no-tool case cannot measure the agent through
that boundary—it would time only the synthetic server—so those cases use the
real turn wall-time gate, not a misleading stub-only stopwatch. Every sample is
retained, and the threshold is exactly `<= 1.0`, with no hidden timing allowance.
Each case also reports the faster harness and median wall-time difference.
The compound evaluation-discovery case uses the same three-run timing gate as
the package-reading MCP workflow. Durable-event/read-model costs are tracked
separately in [issue #5](https://github.com/meoyawn/happen/issues/5); a passing
discovery result does not override a failed timing or envelope check.

The app retains its read-only model-buffer inspector. Neither that snapshot nor
a reconstructed request is used by this contract. The obsolete CLI prepared-input,
context-export, and trace-reducer paths have been removed.
