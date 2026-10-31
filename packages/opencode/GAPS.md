# OpenCode compatibility gaps

Target: OpenCode `e8238bae9b807b72ecfc75afd3a9fe2e6b07b944` in
`/Users/meoyawn/Developer/github/opencode`.

These are outstanding differences and verification gaps. Passing the captured
search cases does not establish complete OpenCode compatibility.

## Outstanding differences

| Area | Current difference | Evidence and completion condition |
| --- | --- | --- |
| Unknown tool diagnostics | The execution proxy returns a generic unknown-tool message. Upstream distinguishes an unknown namespace, an unknown tool with a ranked suggestion, and a namespace that is not callable. | `lib/src/code_mode.dart` versus upstream `packages/codemode/src/tool-runtime.ts` (`namespaceKeys` and `resolve`). Capture these execution failures upstream and match their kinds, text, and suggestions. |
| External tool validation | The Code Mode adapter forwards external tool arguments and results without running upstream ToolRuntime's complete schema validation path. Native tool validation and search-argument validation do not establish external tool input/output parity. | `lib/src/code_mode.dart` versus upstream `ToolRuntime.make` and `Tool.make`. Capture invalid inputs, invalid outputs, argument counts, and structured diagnostics, then verify the Dart bridge. |
| Date instructions | Upstream emits `Today's date:` initially and `Today's date is now:` when the observed day changes. Happen's provider has no corresponding date instruction. | `lib/src/instructions.dart` versus upstream `packages/core/src/instructions/builtins.ts`, instruction key `core/date`. Test initial dates, midnight transitions, resume, and compaction against the upstream observation/rendering path. |
| Instruction lifecycle | System prompt bytes and file/MCP rendering are covered, but discovery, caching, byte budgets, and environment observation follow Happen's shared agent policy. The upstream instruction observation/admission lifecycle, including skills and reference entries, is not reproduced in full. | `../agent/lib/src/instructions.dart`, `../agent/lib/agent.dart`, and upstream `packages/core/src/session/context.ts` and instruction services. Compare complete instruction snapshots and chronological updates in actual sessions. |
| Execution semantics | Happen uses a QuickJS adapter and a compilation heuristic for the final expression. Its `fetch` wrapper is partial. The complete upstream JavaScript runtime, expression handling, fetch surface, and error formatting have not been reproduced or differentially verified. | `lib/src/code_mode.dart` and `../code_mode/lib/src/quickjs.dart`. Capture execution cases from upstream, including control flow, malformed programs, fetch failures, logs, and cancellation, before claiming full execution parity. |
| Background jobs | `shell.background` selects task ownership; foreground shells and all MCP calls follow their caller. Background results are delivered at the next model step or turn; completion does not automatically resume an idle task. Upstream's full Job service and promotion of an active foreground job into the background are absent. | Upstream `packages/core/src/tool/plugin/shell.ts` and `packages/core/src/shell.ts`; `../../test/tool_cancellation_test.dart` verifies the selected lifecycle through the real server. |
| Tool and plugin inventory | Interactive approvals, delegated agents, PDF/audio media, and the complete upstream plugin/runtime surface are missing. Inline images from `read` and MCP tools are supported. Process/history ownership, task storage, engine limits, and transport bounds remain Happen implementations. | `lib/src/tool_specs.dart`, `lib/src/tool_interface.dart`, `lib/src/native_tools.dart`, and upstream `packages/core/src/tool/plugin/`. Compare each implemented tool's complete description, schema, result, and failure behavior with upstream. |
| Image encoding | Tool images follow OpenCode's 2000px / 5 MiB base64 limits, PNG preservation rules, and JPEG quality/size fallback. The Dart codecs and cubic resampling differ from Photon/Lanczos3, so pixels and encoded sizes can differ. User attachments still enter through Happen's existing shared input preparation. | `lib/src/images.dart` versus upstream `packages/core/src/image.ts`, `image/photon-normalize.ts`, and `tool.ts`. Native `read`, MCP Code Mode, normalization, and both wire formats were exercised through Dart MCP; full live-provider equivalence is not established. |

## Verification gaps

Portable fixtures contain 58 search/validation/signature cases, nine catalog and
update cases, and 37 file/MCP instruction cases. They execute the Dart port
against expected results captured from pinned upstream TypeScript with Effect
4.1.0 and diff 8.0.4 under Bun. The search capture ran the actual
`ToolRuntime.prepare`/`make`/`search` path; the catalog and instruction captures
used upstream pure functions with minimal service adapters.

These cases cover selected inputs, not the complete OpenCode application or
every registry, schema, and instruction lifecycle. Integration tests verify the
Happen bridge, native-versus-nested tool placement, MCP decoding, cancellation,
legacy task upgrade, resume, and compaction. They do not compare complete
upstream and Happen sessions. The Console and native DeepSeek transports share
this tool interface, but live provider quality, prompt-cache behavior, and other
operating systems were not benchmarked for this refactor. Verification was on
macOS arm64.

## Resolved mismatches

The provider previously inherited Codex's discovery surface. It now uses
OpenCode's global `search()` inside `execute`, weighted path matching, plural
alternatives, exact bracket paths, namespace scopes, paging, and upstream
argument errors. Captured cases also corrected TypeScript signatures, catalog
allocation and delta text, MCP namespace normalization, and instruction diffs.

MCP guidance is now separate from searchable namespace descriptions. Structured
results, text JSON decoding, output-schema handling, and MCP error messages
were corrected. Legacy task replay and compaction no longer restore the old
eager external tool catalog or shared Happen system prompt.

Regression coverage lives in `../../test/provider_search_test.dart`,
`../../test/provider_instructions_test.dart`, `../../test/tool_interfaces_test.dart`,
and `../../test/deepseek_server_test.dart`.
