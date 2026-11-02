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
and also runs from source. The existing `build-cli` task remains cached
for release builds and future compiled-CLI E2E checks.

The fixed target launches the Dart tests through `tool/test_e2e.dart` with an
empty temporary home and a minimal environment. This also isolates Happen's real
shell/MCP children from the caller's startup files and credentials. Direct
unisolated invocation of this test file is rejected. Each pair's Dart MCP
processes additionally receive the same explicit fixture environment.
The real `dart mcp-server --help` command prepares the SDK's server package once
before either harness starts, outside timing. Measured runs use fresh server
processes; no discovery response or tool result is substituted.
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
Hosted web search is explicitly disabled in both test configurations; this suite
uses real local tools/MCP rather than substituting a hosted-search service.

Global skill discovery is explicitly redirected to the same temporary
`home/.agents/skills` directory: Codex receives that generated `HOME`, and Happen
receives the same `skillsHome` through its production embedding API. The
`global_skills` fixtures populate that directory. Repository `.agents/skills`
fixtures remain separate. Each context must list exactly `catalog_skills`; any
extra user, bundled, or plugin skill fails the isolation assertion.

**Only the Responses API is synthetic.** `cases.dart` supplies native output
arrays. The local HTTP peer emits real Responses SSE and advances a scripted
step only after the previous call IDs have actual tool results. File operations,
JavaScript, SQLite, instruction discovery, skills, tool search, and MCP execution
are real. The MCP case starts independent real `dart mcp-server` processes,
registers the fixture package, and reads its package URI. It does not probe or
interact with the human's desktop app.

## Assertions and evidence

Every initial context and model request is compared for exact equality after
normalizing generated protocol item IDs, equivalent native message encodings,
and runtime-owned wall times/chunk IDs within code-mode output. Tool declarations,
printed values, roles, message boundaries, dates, settings, and tool results are
not discarded. Transport-only client metadata is retained in evidence but is
not a model-visible envelope field. There is no similarity threshold, judge,
golden copied from Happen, or expected-failure bypass. An unsupported Codex
capability is a real failure to fix or configure consistently, not a passing
approximation.

The suite also independently checks AGENTS.md selection and overrides,
metadata-only skill discovery, full skill reads, deferred tool discovery,
real MCP results reaching inference, resumed input retention, and real automatic
compaction. Compaction is triggered by synthetic reported token usage; both real
loops must request it, install the synthetic native checkpoint, restore rules
and skills once, and remove the old real shell receipt from visible context.

Results are written to a new ignored `.local/context-contract/TIMESTAMP/`
directory. It retains both configs, the catalog
checksum, Codex version, complete raw/canonical inputs and requests, the first
differing line, individual timing samples, and a JSON report. Failures exit
nonzero. These artifacts are the evidence when the strict parity contract is red.

### Remaining Code Mode gaps

The Standard Responses envelope is aligned apart from real tool capabilities:

- Codex exposes `exec` plus resumable cells through `wait`. Happen exposes only
  `exec`; `yield_time_ms` is rejected, not silently ignored or advertised.
- Codex uses a V8 async module. Happen uses a fresh QuickJS async function with
  different CPU/memory bounds and currently waits for outstanding host promises.
  Happen exposes a `console.log` alias; Codex's runtime contract has no console.
- Codex also advertises `exit`, `notify`, timers, `yield_control`, audio and
  generated-image helpers. These are not implemented or declared by Happen.
- Eager nested catalogs differ. Happen includes durable-history services and a
  short-lived shell helper; its task-owned shell sessions do not support TTYs.
  This Codex profile additionally exposes `clock__curr_time`. Host-tool
  descriptions, schemas and the shared MCP TypeScript preamble also differ.

Do not copy Codex's description, add dummy `wait` declarations, or omit `tools`
from equality to turn this gate green. Resumable-cell lifecycle, cancellation,
incremental output and notification delivery need genuine runtime support first.

## Timing gates

Prompt preparation has one untimed warm-up followed by alternating execution
order. Happen's in-process median must not exceed Codex's CLI median. The report
labels those different measurement boundaries explicitly; this is not a claim
that CLI startup has been benchmarked fairly against a function call.

For real tool and compaction workflows, three runs alternate harness order. The
peer separately measures both real loops from the first model request through
the final synthetic SSE. Happen's median must not exceed Codex's at that shared
boundary either. A one-response/no-tool case cannot measure the agent through
that boundary—it would time only the synthetic server—so those cases use the
real preparation gate, not a misleading stub-only stopwatch. Every sample is
retained, and the threshold is exactly `<= 1.0`, with no hidden timing allowance.

Desktop and CLI exports both use `readContextSnapshot`, which reads all pages of
one immutable snapshot of the agent's real model buffer. The independent
`happen debug prompt-input`, `debug context`, and optional native tracing remain
available for local diagnostics; this test does not need them as CLI processes.
