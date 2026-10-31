import 'package:ai/ai.dart';
import 'package:protocol/protocol.dart';

import 'skills.dart';

// OpenCode e8238bae9b807b72ecfc75afd3a9fe2e6b07b944. See tools/UPSTREAM.md.
const executeDefinition = ToolDefinition(
  name: 'execute',
  description: 'Run JavaScript in a confined Code Mode runtime to script tool calls and HTTP requests and compose their results.\n'
    '`fetch` is available for HTTP requests. Imports, direct filesystem access, and timers are unavailable: there is no `setTimeout` or sleep. All other external access goes through `tools`.\n'
    'Within `{ code }`, the only callable tools are those explicitly listed in the Code Mode catalog instructions or returned by the `search` function. Inside `{ code }`, ignore tools shown outside the Code Mode catalog. They are not available in the Code Mode runtime.\n'
    'Call tools through `tools` using only exact paths and signatures from the catalog. Do not infer or normalize tool names; preserve bracket notation such as `tools.<namespace>["tool-name"](input)`.\n'
    'Prefer an explicit `return`; if omitted, the final top-level expression becomes the result.\n'
    'Await every call whose completion matters; pending calls are interrupted when execution ends. Run independent calls concurrently with `Promise.allSettled`.',
  parameters: {'type': 'object', 'properties': {'code': {'type': 'string'}}, 'required': ['code'], 'additionalProperties': false},
);

final openCodeDefinitions = <ToolDefinition>[
  executeDefinition,
  skillDefinition,
  ToolDefinition(name: 'shell', description: 'Execute a shell command and return its output. Quote file paths containing spaces or special characters. Prefer dedicated tools over shell commands when possible. When output is large, the full result is saved to a file and a truncated preview is returned. Rely on automatic truncation unless filtering the output is more useful. Commands accept an optional timeout, background commands have no timeout by default. Background commands return immediately, and you will be notified when they complete.', parameters: _object({
    'command': _string('Shell command string to execute'),
    'workdir': _string('Working directory to execute the command in. Defaults to the current working directory. When possible, avoid changing directories in the command and set the working directory here instead.'),
    'timeout': {'type': 'integer', 'minimum': 0, 'description': 'Timeout in milliseconds. Set to 0 to disable the timeout. Defaults to 120000 for foreground commands. Background commands have no timeout by default.'},
    'background': {'type': 'boolean', 'description': "Run the command in the background and return immediately (useful for dev servers and long-running builds). You do not need to use '&' at the end of the command when using this parameter. You will be notified when it completes. DO NOT poll for completion."},
  }, ['command'])),
  ToolDefinition(name: 'read', description: 'Read the contents of a file or directory. Each text line is prefixed by its 1-based line number as <line>: <content>. The prefix is for reference and is not part of the file content. Directory entries are returned one per line. Use offset and limit to read large files or directories in sections. Prefer one larger read over many small slices, and use grep to find specific content in large files.', parameters: _object({
    'path': _string('File or directory to read'),
    'offset': {'type': 'integer', 'minimum': 0, 'description': 'The line or directory entry to start reading from (1-based)'},
    'limit': {'type': 'integer', 'minimum': 0, 'description': 'The maximum number of lines or directory entries to read (defaults to and capped at 2000)'},
  }, ['path'])),
  ToolDefinition(name: 'write', description: 'Writes a file to the local filesystem, overwriting if one exists.\n\nMissing parent directories are created automatically.\n\nUse this tool to create new files or overwrite existing files. For partial changes, use the edit tool instead.', parameters: _object({
    'path': _string('Path to the file to write to'), 'content': _string('Content to write to the file'),
  }, ['path', 'content'])),
  ToolDefinition(name: 'edit', description: 'Edits a file by replacing exact text. Use replaceAll to replace every occurrence; otherwise oldString must match exactly once.', parameters: _object({
    'path': _string('File to edit'), 'oldString': _string('Exact text to find and replace'),
    'newString': _string('Text to replace oldString with (must differ from oldString)'),
    'replaceAll': {'type': 'boolean', 'description': 'Whether to replace every occurrence of oldString. When false, oldString must match exactly once. Defaults to false.'},
  }, ['path', 'oldString', 'newString'])),
  ToolDefinition(name: 'patch', description: 'Apply a patch to add, update, move, or delete files. Supply the complete *** Begin Patch ... *** End Patch text in patchText.', parameters: _object({
    'patchText': _string('The full patch text describing add, update, and delete operations'),
  }, ['patchText'])),
  ToolDefinition(name: 'glob', description: 'Search file paths using a glob pattern (examples: "**/*.ts", "src/**/*.tsx").', parameters: _object({
    'pattern': _string('Glob pattern to match files against'), 'path': _string('Directory to search. Defaults to the current working directory.'),
    'hidden': {'type': 'boolean', 'description': 'Include hidden files and directories (default: false).'},
    'limit': {'type': 'integer', 'minimum': 1, 'description': 'Maximum number of matching files to return (default: 100)'},
  }, ['pattern'])),
  ToolDefinition(name: 'grep', description: "Search file contents using ripgrep's regular expression syntax or literal text matching. Use it to locate specific code, symbols, or text patterns, and narrow searches with `path` or `include`. Returns matching file paths, line numbers, and line previews.", parameters: _object({
    'pattern': {'type': 'string', 'minLength': 1, 'description': 'Regular expression or literal text to match in file contents.'},
    'path': _string('File or directory to search. Defaults to the current working directory.'),
    'include': _string('Glob pattern to filter files (for example, "*.js" or "*.{ts,tsx}")'),
    'literal': {'type': 'boolean', 'description': 'Treat `pattern` as exact text instead of a regular expression (default: false).'},
    'caseSensitive': {'type': 'boolean', 'description': 'Use case-sensitive matching (default: true).'},
    'limit': {'type': 'integer', 'minimum': 1, 'description': 'Maximum number of matching lines to return (default: 100)'},
  }, ['pattern'])),
  ToolDefinition(name: 'websearch', description: "Search the web using the user's selected search integration. Use this for current information beyond knowledge cutoff.", parameters: _object({
    'query': _string('Websearch query'),
  }, ['query'])),
  ToolDefinition(name: 'webfetch', description: 'Fetch content from an HTTP or HTTPS URL and return it as text, markdown, or HTML. Markdown is the default.\n\nUse a more targeted tool when one is available. This tool is read-only. Large text results may be replaced with a preview while the complete output is retained in managed storage.', parameters: _object({
    'url': _string('The HTTP or HTTPS URL to fetch content from'),
    'format': {'type': 'string', 'enum': ['text', 'markdown', 'html'], 'description': 'The format to return the content in. Defaults to markdown.'},
    'timeout': {'type': 'number', 'exclusiveMinimum': 0, 'maximum': 120, 'description': 'Optional timeout in seconds (maximum: 120)'},
  }, ['url'])),
];

Json _string(String description) => {'type': 'string', 'description': description};
Json _object(Json properties, List<String> required) => {
  'type': 'object', 'properties': properties, 'required': required, 'additionalProperties': false,
};
