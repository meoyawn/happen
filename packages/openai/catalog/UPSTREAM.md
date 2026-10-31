# Codex model catalog

- Repository: https://github.com/openai/codex
- Revision: `2681f8cba2831ef72bca2c0672b2e49d5f690745`
- Path: `codex-rs/models-manager/models.json`
- SHA-256: `1384625c0b6b3e67d3c60da29becea2b017f2c283fc1e2d05b8edafb4698eb10`
- Copied unchanged on 2026-10-30. Upstream license is included as `LICENSE`.

Regenerate Dart constants from the repository root:

    dart run tool/embed_model_catalogs.dart

The upstream catalog describes model capabilities. Happen exposes only implemented
features, and initially selects the five GPT-6 models in `src/catalog.dart`.
Base prompt text comes from the selected entry without rewriting the catalog.
Provider-owned tool declarations state the capabilities implemented by this runtime.
There is no shared Happen instruction overlay. Tool/search pins are documented in
[`../tools/UPSTREAM.md`](../tools/UPSTREAM.md).
