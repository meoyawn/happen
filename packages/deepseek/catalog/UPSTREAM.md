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

The initial runtime supports `deepseek-flash` with text and the shared Codex tools.
Other entries and input modalities remain advisory, not advertised capabilities.
The upstream catalog contains no model-specific prompt text. Its headless bundle
uses `You are a coding agent powered by the {{model}} model.`; this package uses
that short persona with the shared harness guidance.
