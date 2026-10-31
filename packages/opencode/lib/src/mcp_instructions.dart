import 'dart:convert';

import 'package:protocol/protocol.dart';

// McpTool.namespace keeps hyphens. The shared transport's callable identifier
// remains in host_name; it must not change the provider's JavaScript paths.
String mcpNamespace(String value) => value.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

String? renderMcpInstructions(List<Json> catalog, List<Json>? previous) {
  Map<String, String> servers(List<Json> tools) {
    final result = <String, String>{};
    for (final tool in tools) {
      final namespace = tool['namespace'] as String? ?? '';
      final instructions = tool['namespace_description'] as String? ?? '';
      if (namespace.startsWith('mcp__') && instructions.isNotEmpty) {
        result[tool['server_name'] as String? ?? namespace.substring(5)] = instructions;
      }
    }
    return {for (final name in result.keys.toList()..sort()) name: result[name]!};
  }
  List<String> entries(Map<String, String> servers) => [for (final server in servers.entries) ...[
    '  <server name="${server.key}">',
    '    Use tools from this server through `execute` under `tools[${jsonEncode(mcpNamespace(server.key))}]`.',
    for (final line in server.value.split('\n')) '    $line',
    '  </server>',
  ]];
  String render(Map<String, String> servers) => ['<mcp_instructions>', ...entries(servers), '</mcp_instructions>'].join('\n');
  final current = servers(catalog), before = previous == null ? null : servers(previous);
  if (before == null) return current.isEmpty ? null : render(current);
  if (current.length == before.length && current.entries.every((entry) => before[entry.key] == entry.value)) return null;
  if (current.isEmpty) return 'MCP server instructions are no longer available.';
  final added = {for (final entry in current.entries) if (!before.containsKey(entry.key)) entry.key: entry.value};
  final changed = {for (final entry in current.entries) if (before.containsKey(entry.key) && before[entry.key] != entry.value) entry.key: entry.value};
  final removed = before.keys.where((name) => !current.containsKey(name)).toList();
  return [
    if (added.isNotEmpty) ...['New MCP server instructions are available in addition to those previously listed:', ...entries(added)],
    if (changed.isNotEmpty) ...['The following MCP server instructions have changed. Each entry replaces the previously listed server with the same name:', ...entries(changed)],
    if (removed.isNotEmpty) 'Instructions for the following MCP servers are no longer available: ${removed.join(', ')}.',
  ].join('\n');
}
