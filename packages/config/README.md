# Happen configuration

This package parses YAML or JSON and validates it against the embedded JSON
Schema. Global configuration supports `mcp_servers` and the boolean
`code_mode_tool_search`, which defaults to `false` for GPT-6.1, matching Codex.

Use the public schema in YAML editors:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/meoyawn/happen/master/packages/config/schema.json
code_mode_tool_search: true
mcp_servers:
  dart:
    command: dart
    args: [mcp-server]
```

`schema.json` is authoritative. After editing it, regenerate the Dart constant
used by JIT and AOT builds:

```sh
dart packages/config/tool/generate_schema.dart
```

For project layers that override individual server fields, use the same URL with
`#/definitions/project`. The merged configuration still requires complete, valid
MCP transports before the server applies it.

The config package owns file locations, loading, watches, and recursive project
layer merging. The server owns executable discovery and MCP process restarts,
applying validated changes through its MCP manager. Model and host settings are
selected through their owning APIs. `code_mode_tool_search` supplies the default
for new GPT threads, including after a config reload; an explicit thread setting
overrides it. Existing threads retain their selected settings. This option is
global; project layers continue to configure MCP servers only.
