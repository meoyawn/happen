# MCP configuration

This package parses YAML or JSON and validates it against the embedded JSON
Schema. Configuration files support only `mcp_servers`.

Use the public schema in YAML editors:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/meoyawn/happen/master/packages/config/schema.json
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
selected through their owning APIs.
