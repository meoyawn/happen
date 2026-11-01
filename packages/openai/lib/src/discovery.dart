import 'package:protocol/protocol.dart';

import 'declarations.dart';
import 'search/bm25.dart';

Json _object(Object? value) => value is Map ? jsonObject(value) : const {};

// The index belongs to the immutable current metadata snapshot, as in Codex's
// ToolSearchHandlerCache. Only one snapshot is retained by this isolate.
List<String> _documents = const [];
BM25Index? _index;

Json discoverTools(List<Json> catalog, Json arguments) {
  final query = requiredString(arguments, 'query').trim();
  final limit = arguments['limit'] ?? 8;
  if (query.isEmpty) throw const FormatException('query must not be empty');
  if (limit is! int || limit < 0) throw const FormatException('limit must be an unsigned integer');
  if (limit == 0) throw const FormatException('limit must be greater than zero');
  final documents = catalog.map(toolSearchText).toList();
  if (_index == null || documents.length != _documents.length ||
      List.generate(documents.length, (index) => index).any((index) => documents[index] != _documents[index])) {
    _documents = documents;
    _index = BM25Index(documents);
  }
  final selected = [for (final row in _index!.search(query, limit)) catalog[row.index]];
  return {'tools': [for (final tool in selected.map(describeTool))
    {'name': tool['name'], 'description': tool['description']}]};
}

// MCP search indexes only the top-level parameter names. Dynamic client tools
// use ToolSearchInfo's recursive schema metadata instead; the two corpora must
// remain distinct even though their declarations use the same renderer.
String toolSearchText(Json tool) {
  final parts = <String>[];
  void push(Object? value) {
    if (value is String && value.trim().isNotEmpty) parts.add(value.trim());
  }
  final namespace = tool['namespace'] as String?;
  final name = tool['tool_name'] as String? ?? tool['name'] as String;
  if (namespace?.startsWith('mcp__') == true) {
    parts.addAll([tool['name'] as String, name, tool['original_name'] as String? ?? name,
      tool['server_name'] as String? ?? namespace!.substring(5)]);
    for (final key in ['title', 'description', 'connector_name', 'namespace_description']) { push(tool[key]); }
    for (final plugin in tool['plugin_display_names'] as List? ?? []) { push(plugin); }
    parts.addAll(_object(_object(tool['parameters'])['properties']).keys.toList()..sort());
  } else {
    if (namespace != null) {
      push(namespace);
      push((tool['namespace_description'] as String? ?? '').trim().isEmpty
        ? 'Tools in the $namespace namespace.' : tool['namespace_description']);
    }
    push(name); push(name.replaceAll('_', ' ')); push(tool['description']);
    void schema(Object? value) {
      if (value is! Map) return;
      push(value['description']);
      final properties = _object(value['properties']);
      for (final name in properties.keys.toList()..sort()) { push(name); schema(properties[name]); }
      schema(value['items']);
      for (final variant in value['anyOf'] as List? ?? []) { schema(variant); }
    }
    schema(tool['parameters']);
  }
  return parts.join(' ');
}
