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
global.

Project icons are saved in the project's `.happen/config.yaml`, alongside its
MCP configuration. Use the project schema (`#/definitions/project`) for this file.
An icon can be an arbitrary local image path, including SVG and PNG:

```yaml
icon: assets/logo.svg
```

Relative paths start in the project directory; absolute paths and `~/` paths
are supported. Files stay in place and are read by the local desktop client.
Desktop watches local project configs and updates project marks when they change.
Checkouts with the same Git repository and subdirectory share that local icon
across machines. Remote files are never read for icons. A configured local
checkout takes precedence; ordinary checkouts precede worktrees, then paths
are ordered alphabetically to choose a consistent source.
Desktop settings can browse for a file, preview it, or choose a Lucide
icon, emoji, or monogram:

```yaml
icon: {kind: lucide, name: rocket, color: blue}
# Or: icon: {kind: emoji, emoji: "🚀"}
# Or: icon: {kind: monogram, text: HP, color: purple}
```

Set `icon: null` to restore the default. Saving through desktop settings updates
the icon atomically and retains the other YAML fields and comments. File reads
and writes belong in worker effects; the config package does not render images.
