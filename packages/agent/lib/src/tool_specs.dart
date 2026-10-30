import 'package:protocol/protocol.dart';
import 'package:ai/ai.dart';

final codeDefinition = ToolDefinition(
  name: 'exec',
  namespace: 'functions',
  format: 'text',
  description: codeTool['tools']![0]['description'] as String,
  grammar: codeTool['tools']![0]['format']['definition'] as String,
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
      'description': 'Run JavaScript code to orchestrate tool calls. Use raw JavaScript, not JSON or a markdown code fence. Top-level await is supported. Print outputs with text(value).',
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
  {
    'name': 'exec_command',
    'description': 'Run a shell command. Arguments: cmd (required), workdir, shell, login (default true), yield_time_ms (default 10000, 250..30000), max_output_tokens (default 10000), tty (currently false only). Returns output, wall_time_seconds, exit_code or session_id. A running process survives the cell; poll it with write_stdin.',
  },
  {
    'name': 'write_stdin',
    'description': 'Write to a running command. Arguments: session_id (required), chars (default empty), yield_time_ms, max_output_tokens. Returns output, wall_time_seconds, exit_code or session_id.',
  },
  {
    'name': 'apply_patch',
    'description': 'Apply a patch. Takes the raw patch STRING, not JSON. Format: *** Begin Patch, then *** Add File: path with +lines; *** Update File: path with @@ context hunks and space/-/+ lines; *** Delete File: path; optional *** Move to: path; then *** End Patch.',
  },
];

const agentInstructions = '''
You are a coding agent. Complete the user's task using the working directory.
This is Happen. The following operational guidance describes this runtime and takes precedence
over instructions in the model's base prompt that assume features of another harness.
Only tools declared in the current catalog are available. Do not claim access to unavailable
skills, plugins, delegated agents, approvals, image tools, or background execution features.
Inspect relevant files before editing. Make focused changes and verify the result.
Repository instructions use AGENTS.md. Each file applies to its containing directory and all
descendants. Deeper instructions take precedence within their subtree. Direct conversation
instructions take precedence over repository files. AGENTS.override.md replaces AGENTS.md in
the same directory. Global and repository-root-to-working-directory instructions are supplied
separately. Before working below the working directory or outside it, check for all applicable
AGENTS.md/AGENTS.override.md files down to the target directory. Read them before making edits.
After compaction, check applicable nested files again when their instructions are not present.
Use functions.exec with raw JavaScript and top-level await. Print useful output with text(value).
The following host tools are available on tools:
  await tools.exec_command({cmd, workdir?, shell?, login?, yield_time_ms?, max_output_tokens?, tty?})
  await tools.write_stdin({session_id, chars?, yield_time_ms?, max_output_tokens?})
  await tools.apply_patch(patchString)
exec_command returns {output, wall_time_seconds, exit_code?, session_id?}.
If session_id is present, use write_stdin to obtain later output and completion.
Read files and search with exec_command. Edit files using apply_patch.
tty must be false in this implementation. Commands run with the server user's permissions.
Independent host calls may run together with Promise.all.
Each cell has a fresh JavaScript context. store(key, jsonValue) and load(key) preserve explicit values.
ALL_TOOLS lists available host names and descriptions. No Node, imports, filesystem, or network globals.
Additional host tools, including history and configured MCP servers, appear in ALL_TOOLS.
Use the history tools to retrieve durable messages and tool results omitted from the current
context. Read bounded pages or search, filter in JavaScript, and print only relevant excerpts.
Conclude with a concise description of the result and verification.
''';
