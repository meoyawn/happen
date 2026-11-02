# OpenCode tool and instruction contracts

Reference repository: [anomalyco/opencode](https://github.com/anomalyco/opencode),
using the current HEAD of `/Users/meoyawn/Developer/github/opencode`.
OpenCode is a moving target, not a version-pinned compatibility contract. Record
the revision and source hashes used for each comparison as evidence; do not
check out an older revision to make a comparison pass.

The provider follows these upstream sources:

- `packages/codemode/src/{tool-runtime,tool-schema}.ts`: global search, input
  validation, exact paths, weighted matching, plural forms, pagination, and
  TypeScript signatures. Search uses a prepared catalog snapshot, not BM25.
- `packages/core/src/codemode/{catalog,instructions}.ts`: the global catalog
  budget, pinned listings, namespace summaries, and full/delta instructions.
- `packages/core/src/session/{system-prompt.ts,runner/prompt/system.txt}`: the verbatim
  system prompt and conditional guidance for the native tools Happen exposes.
- `packages/core/src/instruction-discovery.ts`: instruction file blocks and
  added/changed/removed text, including jsdiff 8.0.4 diffs with three context lines.
- `packages/core/src/{mcp/instructions,tool/mcp}.ts`: separate server guidance,
  canonical MCP namespaces, and MCP value decoding.
- `packages/core/src/tool/plugin/`: the implemented native file, shell, resource,
  and web tool contracts. Native tools stay outside `execute`.

The Console and legacy native DeepSeek transports use this same provider-owned
tool interface. The shared agent supplies execution services without imposing
Codex names, declarations, or instructions. The process runner, patch engine,
and JavaScript engine are reused with OpenAI. Tool paths retain hyphens and use
bracket notation when necessary; shared transport identifiers remain internal.

Existing fixtures were captured by executing upstream TypeScript search/catalog
and instruction renderers under Bun with Effect 4.1.0 and diff 8.0.4. Their
recorded revisions are capture provenance, not the current compatibility target.
Expected results remain independent of Dart. Source hashes, cases, and
reproduction details live in `test/fixtures/tool_search/` at the workspace root.
Compare new behavior against the reference checkout's current source and retain
exact ordering, declarations, prompt text, and error checks. Historical fixture
success alone does not establish compatibility with current upstream.

Upstream MIT text is in `OPENCODE-LICENSE`;
the Dart instruction-diff port's BSD notice is in `JSDIFF-LICENSE`.

Skills use `packages/core/src/tool/plugin/skill.ts` for the native `skill({id})`
contract and `packages/core/src/skill.ts` for model output. The independent output
fixture is `test/fixtures/skills/opencode.json`. Catalog discovery and bounded
presentation are shared server/agent behavior; OpenCode's unbounded catalog and
its permission/plugin subsystems are not ported.
