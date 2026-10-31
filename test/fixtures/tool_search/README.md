# Captured upstream contracts

These expected results were generated outside this repository by executing
upstream code. The Dart implementation never generates its own expected values.
Pins and source SHA-256 hashes are recorded in the JSON files.

| Fixture | Executed upstream code | Coverage |
| --- | --- | --- |
| `openai.json` | Codex `67f0994b`, unchanged MCP/dynamic metadata builders and schema renderer; pinned `bm25` Rust runtime | 27 metadata/ranking queries, 30 float32 scoring cases, normalization, 32 schema/reference/budget cases |
| `openai_tokens.json` | The same Rust tokenizer | 185 captured punctuation, identifier, Unicode, and mixed numeric/letter cases |
| `openai_catalog.json` | Codex `render_namespace_groups` and unchanged `tools_budget.rs` | 17 snapshot, delta, character limit, UTF-8 budget, and omission cases |
| `openai_declarations.json` | Codex callable-name flattening, identifier normalization, and declaration renderer | 13 namespace defaults, underscore boundaries, freeform input, and structured output cases |
| `opencode.json` | OpenCode `e8238bae`, `ToolRuntime.prepare`/`make`/`search`, schema and catalog renderers | 58 queries, argument errors, scopes, paging, collisions, signatures; nine catalog and update cases |
| `opencode_instructions.json` | OpenCode file/MCP renderers with upstream jsdiff | 37 initial, added, changed, removed, multiline, newline, and diff/replacement cases |

Repeated catalogs and description strings are stored once and referenced by
index. Fixtures contain only synthetic tool metadata and instruction files.

The Codex capture used a temporary Rust executable with exact Cargo versions
`bm25=2.3.2`, `deunicode=1.6.2`, `unicode-segmentation=1.12.0`,
`rust-stemmers=1.2.0`, and `serde_json=1.0.149`. Minimal host type adapters called
the unchanged upstream metadata functions. Scoring uses the same
`EmbedderBuilder::with_fit_to_corpus(Language::English, corpus)` and
`Scorer::matches` path as `ToolSearchHandler`. The schema and namespace budget
functions were compiled from upstream source. This does not require building
the complete Codex application. Equal BM25 scores have unspecified Rust ordering;
tests compare the exact scores and descending ranks without prescribing that tie.
Declaration capture calls the unchanged `code_mode_name_for_tool_name`,
`augment_tool_definition`, and schema renderer with minimal metadata adapters.
Those adapters supply dynamic namespace defaults and MCP output wrappers as the
upstream handlers do; the rendered names and descriptions come from Rust.

The OpenCode capture used unchanged `tool-runtime.ts`, `tool-schema.ts`,
`tool.ts`, `tool-error.ts`, and `namespace.ts` with `effect@4.1.0` under Bun.
Synthetic JSON schemas were passed to `Tool.make`; search ran through
`Effect.runPromise(runtime.search(args))`. Catalog and instruction renderers used
their upstream pure functions with service/layer imports removed and equivalent
host adapters. `diff@8.0.4` generated instruction patches. Search cases include
the cases from upstream `codemode.test.ts` and `signature.test.ts`, plus boundary
and malformed input cases. System prompt bytes were captured from
`SessionSystemPrompt.make` with shell/write/edit enabled.

Capture environment: macOS arm64, Bun 1.4.4, Rust 1.96.0. Dart verification uses
Dart 3.13.7 and Flutter 3.47.8. A broader temporary tokenizer comparison also
checked 2,304 strings against Rust with zero differences; the representative
185-string capture remains in the portable test suite.

Run from the workspace root:

```sh
dart test test/provider_search_test.dart test/provider_instructions_test.dart --reporter expanded
dart test test/tool_interfaces_test.dart test/context/discovery_test.dart test/deepseek_server_test.dart --reporter expanded
```

`provider_instructions_test.dart` also verifies SHA-256 digests of the selected
Codex model prompts and OpenCode system prompt. Integration tests cover native
versus nested discovery, in-cell catalog updates, cold resume, repeated native
searches, legacy task upgrade, compaction, cancellation, and shared execution.
The provider `tools/UPSTREAM.md` files record source pins and contract ownership.
