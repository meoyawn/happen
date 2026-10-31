# DeepSeek Harness model catalog

- Repository: https://github.com/deepseek-ai/deepseek-harness
- Revision: `ce7073d51254c26cd63b22a60835b8f948deb447`
- Path: `packages/llm/llm-deepseek/src/models.ts`
- Original file: `upstream-models.ts`, copied unchanged
- Original SHA-256: `8c088f2c66b30c066dac77b7f277f17bd3f8cddcbdc5004c8295facfb39ebdea`
- Copied on 2026-10-30. Upstream license is included as `LICENSE`.

`models.json` is the literal advisory catalog expressed as JSON. The upstream
TypeScript constant `OFFICIAL_CONTEXT_WINDOW` is expanded to `1048576`.
Regenerate Dart constants with `dart run tool/embed_model_catalogs.dart`.

The legacy native runtime supports `deepseek-flash` with text.
Other entries and input modalities remain advisory, not advertised capabilities.
The default Console route uses `deepseek-v4.1-flash-free` from OpenCode's
`fa96f42f6cd8bf21f11fd5b38d78e2dd34d5563e` models-dev snapshot (200,000 context,
32,000 output tokens). Both routes use the provider-owned OpenCode tool interface
and verbatim OpenCode system prompt. Tool, instruction, and search pins are
documented in [`../tools/UPSTREAM.md`](../tools/UPSTREAM.md).
