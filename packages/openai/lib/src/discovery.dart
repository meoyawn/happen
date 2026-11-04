import 'package:protocol/protocol.dart';

import 'declarations.dart';
import 'search/bm25.dart';

Json _object(Object? value) => value is Map ? jsonObject(value) : const {};

// The index belongs to the immutable current metadata snapshot, as in Codex's
// ToolSearchHandlerCache. Only one snapshot is retained by this isolate.
List<String> _documents = const [];
BM25Index? _index;
List<Json>? _catalogSnapshot;
List<Json> _nativeParameters = const [];

void prepareToolSearch(List<Json> catalog) {
  if (identical(catalog, _catalogSnapshot)) return;
  final documents = catalog.map(toolSearchText).toList();
  if (_index == null || documents.length != _documents.length ||
      List.generate(documents.length, (index) => index).any((index) => documents[index] != _documents[index])) {
    _documents = documents;
    _index = BM25Index(documents);
  }
  // A catalog revision replaces the immutable snapshot, including schemas.
  // Codex normalizes these while building its router, before inference.
  _nativeParameters = [for (final tool in catalog) _nativeSchema(tool['parameters'])];
  _catalogSnapshot = catalog;
}

// Codex's tools/json_schema/types.rs serializes this subset for native tools.
// Walk schema positions only: enum values and property names are ordinary data.
Json _nativeSchema(Object? value) {
  if (value is bool) return {'type': 'string'};
  final schema = _object(value);
  final result = <String, dynamic>{};
  for (final key in [r'$ref', 'type', 'description', 'encrypted', 'enum', 'items',
    'minItems', 'properties', 'required', 'additionalProperties', 'anyOf',
    'oneOf', 'allOf', r'$defs', 'definitions']) {
    final value = schema[key];
    if (value == null) continue;
    result[key] = switch (key) {
      'properties' || r'$defs' || 'definitions' =>
        {for (final entry in _object(value).entries) entry.key: _nativeSchema(entry.value)},
      'items' => _nativeSchema(value),
      'additionalProperties' => value is bool ? value : _nativeSchema(value),
      'anyOf' || 'oneOf' || 'allOf' => [for (final item in value as List) _nativeSchema(item)],
      _ => value,
    };
  }
  if (result['type'] == 'object') result.putIfAbsent('properties', () => <String, dynamic>{});
  if (result['type'] == 'array') result.putIfAbsent('items', () => {'type': 'string'});
  return result;
}

Json discoverTools(List<Json> catalog, Json arguments, {bool native = false}) {
  final query = requiredString(arguments, 'query').trim();
  final limit = arguments['limit'] ?? 8;
  if (query.isEmpty) throw const FormatException('query must not be empty');
  if (limit is! int || limit < 0) throw const FormatException('limit must be an unsigned integer');
  if (limit == 0) throw const FormatException('limit must be greater than zero');
  prepareToolSearch(catalog);
  final selected = _index!.search(query, limit);
  if (native) {
    final tools = <Json>[], namespaces = <String, Json>{};
    for (final row in selected) {
      final tool = catalog[row.index];
      // Codex omits output schemas from native deferred definitions. MCP
      // responses can include timing text and content blocks.
      final spec = <String, dynamic>{
        'type': tool['format'] == 'text' ? 'custom' : 'function',
        'name': tool['tool_name'] ?? tool['name'], 'description': tool['description'] ?? '',
        'defer_loading': true,
        if (tool['format'] == 'text') 'format': {'type': 'text'}
        else ...{'strict': false, 'parameters': _nativeParameters[row.index]},
      };
      final namespace = tool['namespace'] as String?;
      if (namespace == null || namespace == 'functions') { tools.add(spec); }
      else {
        final group = namespaces.putIfAbsent(namespace, () {
          final description = (tool['namespace_description'] as String? ?? '').trim();
          final group = <String, dynamic>{'type': 'namespace', 'name': namespace,
            'description': description.isEmpty ? 'Tools in the $namespace namespace.' : description, 'tools': <Json>[]};
          tools.add(group);
          return group;
        });
        (group['tools'] as List).add(spec);
      }
    }
    return {'tools': tools};
  }
  return {'tools': [for (final tool in selected.map((row) => describeTool(catalog[row.index])))
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
