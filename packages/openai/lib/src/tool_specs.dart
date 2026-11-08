import 'package:protocol/protocol.dart';
import 'package:ai/ai.dart';

import 'declarations.dart';
import 'history_tools.dart';
import 'image_generation.dart';
import 'goals.dart';
import 'web_search.dart';

ToolDefinition codeDefinition({required bool deferredTools, bool webSearch = true, bool imageGeneration = false, bool goals = true, bool codeModeOnly = true}) => ToolDefinition(
  name: 'exec', namespace: 'functions', format: 'text',
  description: _codeDescription(deferredTools, webSearch, imageGeneration, goals, codeModeOnly), grammar: _codeGrammar,
);

ToolDefinition directDefinition(Json tool) => ToolDefinition.fromJson({
  ...tool, 'name': tool['tool_name'] ?? tool['name'],
  'description': describeTool(tool, namespaceInstructions: false)['description'],
  if (tool['name'] == 'apply_patch') 'grammar': _patchGrammar,
});

ToolDefinition get directSearchDefinition => ToolDefinition(
  name: 'tool_search', description: toolSearchDefinition.description, format: 'search',
  native: {'gpt': {'type': 'tool_search', 'execution': 'client',
    'description': toolSearchDefinition.description, 'parameters': toolSearchDefinition.parameters}},
);

const sleepDefinition = ToolDefinition(
  name: 'sleep', namespace: 'clock', namespaceDescription: 'Tools for reading and waiting on time.',
  description: 'Pause execution for a specified duration. The sleep ends early when new input arrives for the active turn. Returns the elapsed wall-clock time.',
  parameters: {'type': 'object', 'properties': {
    'duration_ms': {'type': 'number', 'description': 'How long to sleep in milliseconds. Must be between 1 and 43200000.'},
  }, 'required': ['duration_ms'], 'additionalProperties': false},
);

const waitDefinition = ToolDefinition(
  name: 'wait', namespace: 'functions',
  description: 'Waits on a yielded `exec` cell and returns new output or completion.\n'
    '- Use `wait` only after `exec` returns `Script running with cell ID ...`.\n'
    '- `cell_id` identifies the running `exec` cell to resume.\n'
    '- `yield_time_ms` controls how long to wait for more output before yielding again. Defaults to 10000 ms.\n'
    '- `max_tokens` limits how much new output this wait call returns. Defaults to 10000 tokens.\n'
    '- `terminate: true` stops the running cell; false or omitted waits for output.\n'
    '- `wait` returns only the new output since the last yield, or the final completion or termination result for that cell.\n'
    '- If the cell is still running, `wait` may yield again with the same `cell_id`.\n'
    '- If the cell has already finished, `wait` returns the completed result and closes the cell.',
  parameters: {
    'type': 'object', 'properties': {
      'cell_id': {'type': 'string', 'description': 'Identifier of the running exec cell.'},
      'max_tokens': {'type': 'number', 'description': 'Output token budget for this wait call. Defaults to 10000 tokens.'},
      'terminate': {'type': 'boolean', 'description': 'True stops the running exec cell; false or omitted waits for output.'},
      'yield_time_ms': {'type': 'number', 'description': 'Wait before yielding more output. Defaults to 10000 ms.'},
    }, 'required': ['cell_id'], 'additionalProperties': false,
  },
);

const toolSearchDefinition = ToolDefinition(
  name: 'tool_search',
  description: '# Tool discovery\n\nSearches over deferred tool metadata with BM25 and exposes matching tools for the next model call.\n\nSome of the tools may not have been provided to you upfront, and you should use this tool (`tool_search`) to search for the required tools. For MCP tool discovery, always use `tool_search` instead of `list_mcp_resources` or `list_mcp_resource_templates`.',
  parameters: {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': 'Search query for deferred tools.'},
      'limit': {'type': 'number', 'description': 'Maximum number of tools to return. Defaults to 8.'},
    },
    'required': ['query'],
    'additionalProperties': false,
  },
);

const _searchGuidance = r'''Use `await tools.tool_search({query: "...", limit: 8})` for BM25-ranked discovery of deferred tools (up to `limit` matches; 8 by default). It returns `{tools: [{name, description}]}` with callable names and full TypeScript declarations. Print results with `text()` and inspect unfamiliar declarations before calling `tools[result.name](arguments)` in a later execution.''';
Json get toolSearchCatalog => {
  ...toolSearchDefinition.toJson(), 'description': _searchGuidance,
  'output_schema': {'type': 'object', 'properties': {
    'tools': {'type': 'array', 'items': {'type': 'object', 'properties': {
      'name': {'type': 'string'}, 'description': {'type': 'string'},
    }, 'required': ['name', 'description'], 'additionalProperties': false}},
  }, 'required': ['tools'], 'additionalProperties': false},
};

// Codex 0.164 wire names and grammar; see docs/decisions.md.
const _codeGrammar = r'''

start: pragma_source | plain_source
pragma_source: PRAGMA_LINE NEWLINE SOURCE
plain_source: SOURCE

PRAGMA_LINE: /[ \t]*\/\/ @exec:[^\r\n]*/
NEWLINE: /\r?\n/
SOURCE: /[\s\S]+/
''';

// Codex core/assets/tools/apply_patch.lark.
const _patchGrammar = r'''start: begin_patch hunk+ end_patch
begin_patch: "*** Begin Patch" LF
end_patch: "*** End Patch" LF?

hunk: add_hunk | delete_hunk | update_hunk
add_hunk: "*** Add File: " filename LF add_line+
delete_hunk: "*** Delete File: " filename LF
update_hunk: "*** Update File: " filename LF change_move? change?

filename: /(.+)/
add_line: "+" /(.*)/ LF -> line

change_move: "*** Move to: " filename LF
change: (change_context | change_line)+ eof_line?
change_context: ("@@" | "@@ " /(.+)/) LF
change_line: ("+" | "-" | " ") /(.*)/ LF
eof_line: "*** End of File" LF

%import common.LF
''';

// Codex code-mode-protocol/description.rs renders eager nested declarations
// into exec itself; tool_search only indexes the deferred external catalog.
String _codeDescription(bool deferredTools, bool webSearch, bool imageGeneration, bool goals, bool codeModeOnly) {
  final guidance = r'''Some deferred nested tools may be omitted from this description. They are still available on the global `tools` object and listed in `ALL_TOOLS`.
To find one, filter `ALL_TOOLS` by `name` and `description`.

Tool availability can change between calls.

MCP tools return the full CallToolResult envelope. Check `isError` before using its content, even when `Promise.allSettled` reports `fulfilled`. Prefer `structuredContent` when present. Text blocks can contain ordinary text or error messages; only use `JSON.parse` when the tool documents JSON output. Print an error result to inspect it before retrying.''';
  if (!codeModeOnly) return [_codeRuntimeDescription, guidance, if (deferredTools) _searchGuidance].join('\n\n');
  final enabled = [
    // Happen-only extensions remain callable and discoverable in ALL_TOOLS,
    // but do not inflate the shared Codex eager declaration on every request.
    ...hostCatalog.where((tool) => tool['name'] != 'shell_command'),
    ...mcpResourceCatalog,
    ...mcpEventCatalog,
    if (deferredTools) toolSearchCatalog,
    if (imageGeneration) imageGenerationCatalog,
    if (goals) ...goalCatalog,
    if (webSearch) webSearchHost,
  ].map((tool) => describeTool(tool, namespaceInstructions: false)).toList()
    ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  return [
    _codeRuntimeDescription,
    guidance,
    'Shared MCP Types:\n```ts\n$sharedMcpTypes\n```',
    for (final tool in enabled.where((tool) => tool['namespace'] == null)) '### `${tool['name']}`\n${tool['description']}',
    for (final tool in enabled.where((tool) => tool['namespace'] != null)) ...[
      '## ${tool['namespace']}\n${tool['namespace_description']}',
      '### `${tool['name']}`\n${tool['description']}',
    ],
  ].join('\n\n');
}

// Codex's async-module/helper contract adapted to the embedded QuickJS engine.
const _codeRuntimeDescription = r'''Run JavaScript code to orchestrate/compose tool calls
- Evaluates the provided JavaScript code in a fresh embedded QuickJS runtime as an async module.
- All nested tools are available on the global `tools` object, for example `await tools.exec_command(...)`. Tool names are exposed as normalized JavaScript identifiers, for example `await tools.mcp__ologs__get_profile(...)`.
- Nested tool methods take either a string or an object as their input argument.
- Nested tools return either an object or a string, based on the description.
- Runs raw JavaScript -- no Node, no file system, no network access, no console.
- Accepts raw JavaScript source text, not JSON, quoted strings, or markdown code fences.
- You may optionally start the tool input with a first-line pragma like `// @exec: {"yield_time_ms": 10000, "max_output_tokens": 1000}`.
- `yield_time_ms` asks `exec` to yield early if the script is still running. Defaults to 30000 ms.
- `max_output_tokens` sets the token budget for direct `exec` results. Defaults to 10000 tokens.
- When the JS code is fully evaluated, the isolate's lifetime ends and unawaited promises are silently discarded.

- Global helpers:
- `exit()`: Immediately ends the current script successfully (like an early return from the top level).
- `text(value: string | number | boolean | undefined | null)`: Appends a text item. Non-string values are stringified with `JSON.stringify(...)` when possible.
- `image(imageUrlOrItem: string | { image_url: string; detail?: "auto" | "low" | "high" | "original" | null } | ImageContent, detail?: "auto" | "low" | "high" | "original" | null)`: Appends an image item. `image_url` should be a base64-encoded `data:` URL. To forward an MCP tool image, pass an individual `ImageContent` block from `result.content`, for example `image(result.content[0])`. MCP image blocks may request detail with `_meta: { "codex/imageDetail": "original" }`. When provided, the second `detail` argument overrides any detail embedded in the first argument.
- `audio(audioUrlOrItem: string | { audio_url: string } | AudioContent)`: Appends an audio item. `audio_url` should be a base64-encoded `data:` URL. To forward an MCP tool audio block, pass an individual `AudioContent` block from `result.content`, for example `audio(result.content[0])`.
- `generatedImage(result: { image_url: string; output_hint?: string })`: Appends an image-generation result and its optional output hint. HTTP(S) URLs are not supported.
- `store(key: string, value: any)`: stores a serializable value under a string key for later `exec` calls in the same session.
- `load(key: string)`: returns the stored value for a string key, or `undefined` if it is missing.
- `notify(value: string | number | boolean | undefined | null)`: immediately injects an extra `custom_tool_call_output` for the current `exec` call. Values are stringified like `text(...)`.
- `setTimeout(callback: () => void, delayMs?: number)`: schedules a callback to run later and returns a timeout id. Pending timeouts do not keep `exec` alive by themselves; await an explicit promise if you need to wait for one.
- `clearTimeout(timeoutId?: number)`: cancels a timeout created by `setTimeout`.
- `ALL_TOOLS`: metadata for the enabled nested tools as `{ name, description }` entries.
- `as_settled(promises: Iterable<any> | Map<any, any>)`: returns an async iterator of `{ index, status, value?, reason? }` results in settlement order. `index` is the input position or Map key.
- `stream_settled(promises: Iterable<any> | Map<any, any>, emit: (result: any) => any)`: processes results in settlement order, awaiting each callback before the next.
- `yield_control()`: yields the accumulated output to the model immediately while the script keeps running.''';

const hostCatalog = <Json>[
  {
    'name': 'curr_time', 'tool_name': 'curr_time', 'namespace': 'clock',
    'namespace_description': 'Tools for reading and waiting on time.',
    'description': 'Return the current time in UTC.',
    'parameters': {'type': 'object', 'properties': <String, Object?>{}, 'additionalProperties': false},
    'output_schema': {'type': 'object', 'properties': {
      'current_time': {'type': 'string', 'description': 'Current UTC time formatted as YYYY-MM-DD HH:MM:SS UTC.'},
    }, 'required': ['current_time'], 'additionalProperties': false},
  },
  {
    'name': 'view_image',
    'description': 'View a local image file from the filesystem when visual inspection is needed. Use this for images already available on disk.',
    'parameters': {
      'type': 'object', 'properties': {
        'path': {'type': 'string', 'description': 'Local filesystem path to an image file.'},
        'detail': {'type': 'string', 'enum': ['high', 'original'], 'description': 'Image detail level. Defaults to `high`; use `original` to preserve exact resolution.'},
      }, 'required': ['path'], 'additionalProperties': false,
    },
    'output_schema': {'type': 'object', 'properties': {
      'image_url': {'type': 'string', 'description': 'Data URL for the loaded image.'},
      'detail': {'type': 'string', 'enum': ['high', 'original'],
        'description': 'Image detail hint returned by view_image. Returns `high` for default resized behavior or `original` when original resolution is preserved.'},
    }, 'required': ['detail', 'image_url'], 'additionalProperties': false},
  },
  {
    'name': 'shell_command',
    'description': 'Run a short shell command to completion. Its process tree is terminated on steering, turn cancellation, cell cancellation, or timeout. Use exec_command for task-owned sessions such as development servers.',
    'parameters': {
      'type': 'object', 'properties': {
        'command': {'type': 'string', 'description': 'Shell command to execute.'},
        'workdir': {'type': 'string', 'description': 'Working directory. Defaults to the current task cwd.'},
        'shell': {'type': 'string', 'description': 'Shell binary. Defaults to the user shell.'},
        'login': {'type': 'boolean', 'description': 'Start a login shell. Defaults to true.'},
        'timeout_ms': {'type': 'number', 'description': 'Maximum command runtime. Defaults to 10000 ms.'},
        'max_output_tokens': {'type': 'number', 'description': 'Output token budget. Defaults to 10000.'},
      }, 'required': ['command'], 'additionalProperties': false,
    },
  },
  {
    'name': 'exec_command',
    'description': 'Runs a command in a PTY, returning output or a session ID for ongoing interaction.',
    'parameters': {
      'type': 'object',
      'properties': {
        'cmd': {'type': 'string', 'description': 'Shell command to execute.'},
        'workdir': {'type': 'string', 'description': 'Working directory for the command. Defaults to the turn cwd.'},
        'tty': {'type': 'boolean', 'description': 'True allocates a PTY for the command; false or omitted uses plain pipes.'},
        'yield_time_ms': {'type': 'number', 'description': 'Wait before yielding output. Defaults to 10000 ms; effective range is 250-30000 ms.'},
        'max_output_tokens': {'type': 'number', 'description': 'Output token budget. Defaults to 10000 tokens; larger requests may be capped by policy.'},
        'shell': {'type': 'string', 'description': "Shell binary to launch. Defaults to the user's default shell."},
        'login': {'type': 'boolean', 'description': 'True runs the shell with -l/-i semantics; false disables them. Defaults to true.'},
        'justification': {'type': 'string', 'description': 'User-facing approval question for `require_escalated`; omit otherwise.'},
        'prefix_rule': {'type': 'array', 'items': {'type': 'string'},
          'description': 'Reusable approval prefix for `cmd`, only with `sandbox_permissions: "require_escalated"`; for example ["git", "pull"].'},
        'sandbox_permissions': {'type': 'string', 'enum': ['use_default', 'require_escalated'],
          'description': 'Per-command sandbox override. Defaults to `use_default`; use `require_escalated` for unsandboxed execution.'},
      },
      'required': ['cmd'], 'additionalProperties': false,
    },
    'output_schema': _commandOutput,
  },
  {
    'name': 'write_stdin',
    'description': 'Writes characters to an existing unified exec session and returns recent output.',
    'parameters': {
      'type': 'object', 'properties': {
        'session_id': {'type': 'number', 'description': 'Identifier of the running unified exec session.'},
        'chars': {'type': 'string', 'description': 'Bytes to write to stdin. Defaults to empty, which polls without writing.'},
        'yield_time_ms': {'type': 'number', 'description': 'Wait before yielding output. Non-empty writes default to 250 ms and cap at 30000 ms; empty polls wait 5000-300000 ms by default.'},
        'max_output_tokens': {'type': 'number', 'description': 'Output token budget. Defaults to 10000 tokens; larger requests may be capped by policy.'},
      }, 'required': ['session_id'], 'additionalProperties': false,
    },
    'output_schema': _commandOutput,
  },
  {
    'name': 'apply_patch',
    'format': 'text',
    'description': 'The `apply_patch` tool can be used to edit files. This is a FREEFORM tool, so do not wrap the patch in JSON.',
  },
];

const _commandOutput = <String, dynamic>{
  'type': 'object', 'properties': {
    'chunk_id': {'type': 'string', 'description': 'Chunk identifier included when the response reports one.'},
    'exit_code': {'type': 'number', 'description': 'Process exit code when the command finished during this call.'},
    'original_token_count': {'type': 'number', 'description': 'Approximate token count before output truncation.'},
    'output': {'type': 'string', 'description': 'Command output text, possibly truncated.'},
    'session_id': {'type': 'number', 'description': 'Session identifier to pass to write_stdin when the process is still running.'},
    'wall_time_seconds': {'type': 'number', 'description': 'Elapsed wall time spent waiting for output in seconds.'},
  }, 'required': ['output', 'wall_time_seconds'], 'additionalProperties': false,
};
