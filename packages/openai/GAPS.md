# OpenAI compatibility gaps

Target: Codex `67f0994b532b8740f14b5b738af7b7b2a915b1d6` in
`/Users/meoyawn/Developer/github/codex`.

These are outstanding differences and verification gaps. Passing the captured
search cases does not establish complete Codex compatibility.

## Outstanding differences

| Area | Current difference | Evidence and completion condition |
| --- | --- | --- |
| Tool instruction text | Model system prompts are copied verbatim, but the descriptions of `functions.exec`, `exec_command`, `write_stdin`, and `apply_patch` in `lib/src/tool_specs.dart` are Happen summaries. The complete tool interface is not word-for-word upstream. | Compare the descriptions and schemas with Codex `code-mode-protocol/src/description.rs`, `core/src/tools/handlers/shell_spec.rs`, and the patch tool spec. Capture the complete supported tool definitions upstream and assert their model-visible text and schemas. |
| Execution helpers | The shared bootstrap exposes `text`, `image`, `store`, `load`, `tools`, and `console.log`. It lacks Codex's `exit`, `notify`, timer helpers, audio helpers, and yielded-cell operations. Image output is retained separately from text, so interleaved text/image ordering is not identical to upstream. | Compare `../code_mode/lib/src/quickjs.dart` with Codex `code-mode-protocol/src/description.rs`. Verify each implemented helper against the upstream runtime before exposing it. |
| Unawaited calls | OpenAI uses the shared runtime's default `awaitPending: true`. Codex ends the isolate after evaluation and discards unawaited promises. Happen can wait for a call that Codex would discard. | `lib/src/tool_interface.dart` and `../code_mode/lib/src/quickjs.dart`; Codex's execution description explicitly specifies this lifetime. Add upstream cases for awaited and unawaited work, errors, and cancellation, then match their results. |
| Process tools | Commands use pipes. PTYs and interactive permission escalation are missing; the `tty` description now advertises only the supported `false` value. Shell host metadata also omits upstream output schemas. | `lib/src/tool_specs.dart`, `lib/src/tools.dart`, and `../tool_runtime/lib/src/process.dart`; compare Codex `core/src/tools/handlers/shell_spec.rs`. Verify PTY behavior, permission arguments, and complete input/output declarations against upstream. |
| Command lifetimes | User-selected behavior: `shell_command({command, ...})` exposes one-shot execution separately, while `exec_command` sessions belong to the active task and survive cells and turns until hibernation/archive/shutdown. The pinned Codex source selects one-shot or resumable behavior for `exec_command`; it does not advertise this separate one-shot declaration. | Codex `core/src/tools/handlers/unified_exec/exec_command.rs` and `core/src/unified_exec/oneshot.rs`; `../../test/tool_cancellation_test.dart` exercises the Happen contract through the real server. |
| Instruction discovery | Codex-style wrappers and replacement text are implemented, but file discovery, caching, byte budgets, and environment observation still follow Happen's shared agent policy. | `../agent/lib/src/instructions.dart` and `../agent/lib/agent.dart`. Compare discovered files, their precedence and updates, and resumed-task instructions with an upstream session; wrapper fixtures alone do not cover this. |
| Equal BM25 scores | Rust HashMap iteration leaves the order of equal scores unspecified. Dart uses registration order. Scores match the captured cases, but identical ordering at a tied result boundary is not established. | `lib/src/search/bm25.dart` and `../../test/provider_search_test.dart`. Exercise tied cutoffs in the actual upstream handler; do not describe tie ordering as proven identical. |
| Runtime and host policies | QuickJS, its memory/CPU/source/host-call limits, process/history ownership, and transport bounds differ from the complete Codex runtime. Delegated agents and the full upstream tool inventory are absent. | `../code_mode/lib/code_mode.dart`, `../code_mode/lib/src/quickjs.dart`, and this provider's tool catalog. Compare observable behavior for each added capability and boundary. |
| Web reader | Direct HTTP recovery after an OpenAI inaccessible-page response is a Happen extension. It recognizes the observed error shape, preserves unfamiliar failures, and uses its own page text and line numbering. Dynamic-only pages and binary/PDF documents are not recovered. | `lib/src/web_pages.dart`, `../../test/openai_web_pages_test.dart`, and `../../docs/evidence/openai-web-pages.json`. The live check covered the reported article and model; other failure shapes and platforms remain unverified. |

## Verification gaps

The portable fixtures execute the Dart implementation against independently
captured upstream results: 27 metadata queries, 30 exact BM25 scoring cases,
185 tokenizer inputs, 32 schemas, 17 namespace snapshots/deltas, and 13 callable
name/declaration cases. A temporary comparison checked 2,304 tokenizer strings
with no differences. These cover selected inputs, not every possible schema,
Unicode input, registry mutation, or complete Codex session.

The Rust capture compiled unchanged upstream metadata, schema, declaration, and
budget functions with minimal host adapters and pinned search dependencies. It
did not run the complete Codex application. Nested search, repeated
searches, catalog refresh, resume, and compaction have Happen integration tests;
the full upstream runtime and Happen have not been compared end to end on the
same session corpus. Live provider quality and prompt-cache behavior have not
been benchmarked for this refactor. Verification was on macOS arm64.

One parallel full-suite run produced an extra retry in the accelerated HTTP
idle-timeout test. The fixture compresses five minutes to 500 ms. The five GPT
transport tests pass in isolation, and all 328 root tests pass with serial
test-file concurrency and a 4096-descriptor limit. The parallel timing failure
has not been eliminated. A separate run with the shell's default 256 descriptors
exhausted file handles and left test processes requiring cleanup.

## Resolved mismatches

Responses and standalone search now use Codex's four request retries with
200 ms exponential backoff and jitter. Responses retain five stream retries;
connection establishment failures during sampling wait 5, 10, 20, 40, then
60 seconds until recovery or cancellation, without consuming that stream budget.
Compaction and search remain bounded. HTTP and streamed errors retain server
`Retry-After` deadlines, and quota/context/invalid-request failures remain terminal.
`../../test/openai_retry_test.dart` covers these policies with controlled transport
failures; `../../test/server_test.dart` verifies reconnect status and that recovery
does not repeat executed tools. The selected transport remains fixed; Codex's
WebSocket-to-HTTP transport switching is not implemented here.

The captured cases caught mutable stemmer reuse, float32 scoring drift, incorrect
MCP/dynamic metadata corpora, the extra exact-name boost and camel-case expansion,
and the 32-result clamp. The Dart implementation now matches the captured
tokenization, scores, limits, and corpus text.

Namespace budget and delta rendering, schema reference/work budgets,
default namespace guidance, underscore joins, and
sorted/deduplicated `ALL_TOOLS` metadata were also corrected. Tests live in
`../../test/provider_search_test.dart`, `../../test/provider_instructions_test.dart`,
`../../test/tool_interfaces_test.dart`, and `../../test/context/`.

Eager nested tools are now declared in `functions.exec`, following Codex's
code-mode-only description builder. This makes shell and patch tools visible
without searching the deferred catalog. Existing tasks receive the current
definition changes as append-only updates, including after compaction. The context
discovery regression verifies those declarations, file reads and edits, and the
reported query's empty deferred result. Complete upstream description text and
unsupported runtime helpers remain the separate gaps above.

OpenAI sessions use the incremental-tools window layout in the pinned
Codex source: tool declarations followed by the developer base prompt in history,
empty top-level `tools`/`instructions`, and one restored prefix at the front after
compaction. Ordinary sessions no longer receive persistent-mode instructions.
`../../test/context/bloat_test.dart` checks multiplicity and order across turns,
resume and repeated compaction. Obsolete envelopes, native discovery routes,
prototype history readers, and their compatibility tests have been deleted.
This fixes the window layout, not the remaining shared instruction-discovery and
world-state rendering differences above. The desktop context inspector still
shows projected session messages rather than a complete provider request dump.
