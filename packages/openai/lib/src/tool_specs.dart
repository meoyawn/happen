import 'package:protocol/protocol.dart';
import 'package:ai/ai.dart';

import 'declarations.dart';
import 'history_tools.dart';
import 'web_search.dart';

ToolDefinition get codeDefinition => ToolDefinition(
  name: 'exec',
  namespace: 'functions',
  format: 'text',
  description: codeTool['tools']![0]['description'] as String,
  grammar: codeTool['tools']![0]['format']['definition'] as String,
);

const toolSearchDefinition = ToolDefinition(
  name: 'tool_search',
  format: 'search',
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

// Codex 0.164 wire names and grammar; see docs/decisions.md.
Map<String, dynamic> get codeTool => <String, dynamic>{
  'type': 'namespace',
  'name': 'functions',
  'description': '',
  'tools': [
    {
      'type': 'custom',
      'name': 'exec',
      'description': _codeDescription(),
      'format': {
        'type': 'grammar',
        'syntax': 'lark',
        'definition': r'''
start: pragma_source | plain_source
pragma_source: PRAGMA_LINE NEWLINE SOURCE
plain_source: SOURCE

PRAGMA_LINE: /[ \t]*\/\/ @exec:[^\r\n]*/
NEWLINE: /\r?\n/
SOURCE: /[\s\S]+/
''',
      },
    },
  ],
};

// Codex code-mode-protocol/description.rs renders eager nested declarations
// into exec itself; tool_search only indexes the deferred external catalog.
String _codeDescription() {
  final enabled = [
    ...hostCatalog.where((tool) => tool['name'] != 'web__run'),
    ...historyCatalog, ...mcpResourceCatalog,
    {...toolSearchDefinition.toJson(), 'format': 'json'},
  ].map(describeTool).toList()..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
  return [
    'Run JavaScript code to orchestrate tool calls. Use raw JavaScript, not JSON or a markdown code fence. Top-level await is supported. Print outputs with text(value). Output defaults to 10000 tokens; override with a first-line // @exec: {"max_output_tokens": 20000} pragma. Oversized text is truncated, preserving its beginning and end.',
    r'''All nested tools are available on the global `tools` object, for example `await tools.exec_command(...)`. Tool names are exposed as normalized JavaScript identifiers.
Nested tool methods take either a string or an object as their input argument.
Nested tools return either an object or a string, based on the description.
Each execution uses a fresh JavaScript context. Use the host tools for file, process, and network access.

Global helpers:
- `text(value)`: Appends a text item. Non-string values are stringified with JSON.stringify when possible.
- `store(key: string, value: any)`: stores a serializable value under a string key for later exec calls in the same session.
- `load(key: string)`: returns the stored value for a string key, or undefined if it is missing.
- `ALL_TOOLS`: metadata for the enabled nested tools as { name, description } entries.''',
    r'''Some deferred nested tools may be omitted from this description. They are still available on the global `tools` object and listed in `ALL_TOOLS`.
To find one, filter `ALL_TOOLS` by `name` and `description`.

Tool availability can change between calls.''',
    r'''Use `await tools.tool_search({query: "...", limit: 8})` for BM25-ranked discovery of deferred tools (up to `limit` matches; 8 by default). It returns `{tools: [{name, description}]}` with callable names and full TypeScript declarations. Print results with `text()` and inspect unfamiliar declarations before calling `tools[result.name](arguments)` in a later execution.''',
    for (final tool in enabled) '### `${tool['name']}`\n${tool['description']}',
  ].join('\n\n');
}

const hostCatalog = <Json>[
  webSearchHost,
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
    'description': 'Start a task-owned shell session, for example a development server. It survives cell cancellation, steering, Stop, and later turns. Hibernating or archiving the task closes it. Use shell_command for short calls that must stop with their caller. Arguments: cmd (required), workdir, shell, login (default true), yield_time_ms (default 10000, 250..30000), max_output_tokens (default 10000), tty (currently false only). Returns output, wall_time_seconds, exit_code or session_id. Poll a session with write_stdin.',
    'parameters': {
      'type': 'object',
      'properties': {
        'cmd': {'type': 'string', 'description': 'Shell command to execute.'},
        'workdir': {'type': 'string', 'description': 'Working directory for the command. Defaults to the turn cwd.'},
        'tty': {'type': 'boolean', 'description': 'Only false or omitted is supported; commands use plain pipes.'},
        'yield_time_ms': {'type': 'number', 'description': 'Wait before yielding output. Defaults to 10000 ms; effective range is 250-30000 ms.'},
        'max_output_tokens': {'type': 'number', 'description': 'Output token budget. Defaults to 10000 tokens; larger requests may be capped by policy.'},
        'shell': {'type': 'string', 'description': "Shell binary to launch. Defaults to the user's default shell."},
        'login': {'type': 'boolean', 'description': 'True starts a login shell (-l); false omits -l. Defaults to true.'},
      },
      'required': ['cmd'], 'additionalProperties': false,
    },
  },
  {
    'name': 'write_stdin',
    'description': 'Write to a running command. Arguments: session_id (required), chars (default empty), yield_time_ms, max_output_tokens. Returns output, wall_time_seconds, exit_code or session_id.',
    'parameters': {
      'type': 'object', 'properties': {
        'session_id': {'type': 'number', 'description': 'Identifier of the running unified exec session.'},
        'chars': {'type': 'string', 'description': 'Bytes to write to stdin. Defaults to empty, which polls without writing.'},
        'yield_time_ms': {'type': 'number', 'description': 'Wait before yielding output. Non-empty writes default to 250 ms and cap at 30000 ms; empty polls wait 5000-300000 ms by default.'},
        'max_output_tokens': {'type': 'number', 'description': 'Output token budget. Defaults to 10000 tokens; larger requests may be capped by policy.'},
      }, 'required': ['session_id'], 'additionalProperties': false,
    },
  },
  {
    'name': 'apply_patch',
    'format': 'text',
    'description': 'Apply a patch. Takes the raw patch STRING, not JSON. Format: *** Begin Patch, then *** Add File: path with +lines; *** Update File: path with @@ context hunks and space/-/+ lines; *** Delete File: path; optional *** Move to: path; then *** End Patch.',
  },
];

