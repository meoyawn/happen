# Codex tool and instruction contracts

Pinned repository: [openai/codex](https://github.com/openai/codex/tree/67f0994b532b8740f14b5b738af7b7b2a915b1d6),
revision `67f0994b532b8740f14b5b738af7b7b2a915b1d6`.

The Dart search port follows these upstream sources:

- `codex-rs/core/src/tools/handlers/{tool_search,mcp,tool_search_spec}.rs`:
  searchable MCP metadata, limits, ranked native and nested results.
- `codex-rs/tools/src/tool_search.rs`: dynamic-tool metadata and schema traversal.
- `codex-rs/core/src/context/world_state/{tools,tools_budget}.rs`: namespace
  snapshots, deltas, description limits, and the shared 4 KiB UTF-8 budget.
- `codex-rs/code-mode-protocol/src/{description,json_schema_types}.rs`:
  JavaScript identifiers, declarations, references, and rendering budgets.
- `codex-rs/core/src/tools/code_mode/execute_spec.rs`: raw-source Lark grammar.

The pinned runtime uses `bm25 2.3.2`, `deunicode 1.6.2`,
`unicode-segmentation 1.12.0`, `rust-stemmers 1.2.0`, and the NLTK list from
`stop-words 0.9.0`. This package implements the tokenizer, FxHash32 embeddings,
corpus fitting, and float32 BM25 scoring in Dart, using the pinned pure Dart
`stemmer 3.2.0`. It has no Rust dependency, native directory, FFI search library,
or search build hook. The existing shared JavaScript engine is separate from
search.

Model system instructions and persistent instructions are copied unchanged from
the model catalog, whose separate pin is in `../catalog/UPSTREAM.md`. They were
compared to this tool revision and are byte-identical for every supported model.
The provider owns Codex's AGENTS.md wrapper, replacement/removal text, project-doc
separator, and environment rendering. The agent adds no shared instruction prose.

Captured upstream executions and source SHA-256 hashes live in
`test/fixtures/tool_search/` at the workspace root. See that directory's README
for provenance and verification commands. Rust was used only in temporary tooling
outside the repository to capture oracle results. Checked-in tests execute Dart.

Upstream Apache-2.0 text is in `CODEX-LICENSE`; transliteration and stop-word
notices are in `DEUNICODE-LICENSE` and `STOPWORDS-LICENSE`.

The code-mode-only description contract also follows
`codex-rs/core/src/tools/spec_plan.rs` (`register_code_mode_executors`) and
`codex-rs/code-mode-protocol/src/description.rs`
(`build_exec_tool_description`): eager nested tool declarations belong in the
exec description; ranked search receives the deferred catalog. Happen renders
its implemented shell, patch, history, resource, and search tools there, with
ALL_TOOLS and nested-search guidance. Web retains its separate eager definition.
Runtime helpers and shell options are described only where implemented; the
upstream V8, yield/wait, media, and PTY capabilities are not claimed.
