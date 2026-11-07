# Codex model catalog

- Repository: https://github.com/openai/codex
- Revision: `efdacaf46ff54660a239189a6d62434c5db33d2c`
- Path: `codex-rs/models-manager/models.json`
- SHA-256: `1384625c0b6b3e67d3c60da29becea2b017f2c283fc1e2d05b8edafb4698eb10`
- Verified unchanged against the local Codex checkout on 2026-11-07. Upstream license is included as `LICENSE`.

Regenerate Dart constants from the repository root:

    dart run tool/embed_model_catalogs.dart

The upstream catalog describes model capabilities. Happen exposes only implemented
features, and initially selects the five GPT-6 models in `src/catalog.dart`.
Base prompt text comes from the selected entry without rewriting the catalog.
The ChatGPT provider discovers current metadata from its authenticated Codex
backend. It caches that catalog for five minutes, falls back to this bundled
catalog when discovery is unavailable, and freezes the resolved model metadata
in each thread. The cache is scoped to the account and endpoint.
Provider-owned tool declarations state the capabilities implemented by this runtime.
There is no shared Happen instruction overlay. Tool/search pins are documented in
[`../tools/UPSTREAM.md`](../tools/UPSTREAM.md).
