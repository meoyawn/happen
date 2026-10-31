import 'package:protocol/protocol.dart';
import 'package:ai/ai.dart';

import 'web_search.dart';

final codeDefinition = ToolDefinition(
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
const codeTool = <String, dynamic>{
  'type': 'namespace',
  'name': 'functions',
  'description': '',
  'tools': [
    {
      'type': 'custom',
      'name': 'exec',
      'description': 'Run JavaScript code to orchestrate tool calls. Use raw JavaScript, not JSON or a markdown code fence. Top-level await is supported. Print outputs with text(value). Output defaults to 10000 tokens; override with a first-line // @exec: {"max_output_tokens": 20000} pragma. Oversized text is truncated, preserving its beginning and end.',
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

const hostCatalog = <Json>[
  webSearchHost,
  {
    'name': 'exec_command',
    'description': 'Run a shell command. Arguments: cmd (required), workdir, shell, login (default true), yield_time_ms (default 10000, 250..30000), max_output_tokens (default 10000), tty (currently false only). Returns output, wall_time_seconds, exit_code or session_id. A running process survives the cell; poll it with write_stdin.',
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

