import 'package:protocol/protocol.dart';

import 'signatures.dart';

const searchInput = <String, dynamic>{
  'type': 'object', 'properties': {
    'query': {'type': 'string'}, 'namespace': {'type': 'string'},
    'limit': {'type': 'integer', 'minimum': 1}, 'offset': {'type': 'integer', 'minimum': 0},
  },
};

// Port of @opencode/codemode tool-runtime.ts at the pinned revision.
Json searchCodeArguments(List<Json> catalog, List<Object?> arguments) {
  if (arguments.length > 1) throw const ToolRuntimeError('InvalidToolInput', "Tool 'search' expects at most one input object.");
  return searchCodeTools(catalog, arguments.isEmpty ? <String, dynamic>{} : arguments.single);
}

class ToolRuntimeError implements Exception {
  const ToolRuntimeError(this.kind, this.message);
  final String kind, message;
  @override
  String toString() => 'ToolRuntimeError: $message';
}

Json searchCodeTools(List<Json> catalog, Object? value) {
  Never invalid(String expected, [String? key]) => throw ToolRuntimeError('InvalidToolInput',
    "Invalid input for tool 'search': SchemaError(Expected $expected${key == null ? '' : '\n  at [${'"$key"'}]'})");
  if (value is! Map) invalid('object');
  final input = jsonObject(value);
  for (final key in ['query', 'namespace']) {
    if (input.containsKey(key) && input[key] is! String) invalid('string', key);
  }
  for (final key in ['limit', 'offset']) {
    if (!input.containsKey(key)) continue;
    final number = input[key];
    if (number is! num) invalid('number', key);
    if (!number.isFinite || number != number.truncateToDouble()) invalid('an integer', key);
    if (key == 'limit' && number <= 0) invalid('a value greater than 0', key);
    if (key == 'offset' && number < 0) invalid('a value greater than or equal to 0', key);
    input[key] = number.toInt();
  }
  catalog = {for (final tool in catalog) tool['name'] as String: tool}.values.toList();
  final query = input['query'] as String? ?? '';
  var namespace = input['namespace'] as String?;
  final limit = input['limit'] ?? 10, offset = input['offset'] ?? 0;
  if (limit is! int || limit <= 0 || offset is! int || offset < 0) {
    throw const FormatException('Invalid search pagination');
  }
  if (!catalog.any((tool) => (tool['name'] as String).startsWith('tools.'))) {
    if (namespace == 'tools') namespace = null;
    if (namespace?.startsWith('tools.') == true) namespace = namespace!.substring(6);
  }
  final scoped = catalog.where((tool) => namespace == null ||
    tool['name'] == namespace || (tool['name'] as String).startsWith('$namespace.')).toList();
  final trimmed = query.trim();
  final path = trimmed.startsWith('tools.') ? trimmed.substring(6) : trimmed;
  final exact = path.isEmpty ? <Json>[] : scoped.where((tool) => tool['name'] == path || toolExpression(tool['name'] as String) == trimmed).toList();
  List<String> words(String text) => text.replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'),
    (match) => '${match[1]} ${match[2]}').toLowerCase().split(RegExp('[^a-z0-9]+'))
    .where((word) => word.isNotEmpty).toList();
  final terms = words(query).map((term) => [term,
    if (term.endsWith('es') && term.length > 3) term.substring(0, term.length - 2),
    if (term.endsWith('s') && term.length > 2) term.substring(0, term.length - 1),
  ]);
  final ranked = <({Json tool, int score})>[];
  for (final tool in scoped) {
    final name = (tool['name'] as String).toLowerCase();
    final description = (tool['description'] as String? ?? '').toLowerCase();
    final properties = schemaProperties(tool['parameters'] is Map ? jsonObject(tool['parameters']) : const {});
    final text = '$name\n$description\n${tool['namespace_description'] ?? ''}\n${properties.entries.map((entry) => '${entry.key} ${entry.value is Map ? entry.value['description'] ?? '' : ''}').join('\n')}'.toLowerCase();
    var score = 0;
    for (final forms in terms) {
      if (forms.any((form) => name == form || name.endsWith('.$form'))) score += 20;
      if (forms.any(words(tool['name'] as String).contains)) score += 12;
      if (forms.any(name.contains)) score += 8;
      if (forms.any(description.contains)) score += 4;
      if (forms.any(text.contains)) score += 2;
    }
    if (terms.isEmpty || score > 0) ranked.add((tool: tool, score: score));
  }
  ranked.sort((a, b) => a.score != b.score ? b.score.compareTo(a.score)
    : (a.tool['name'] as String).compareTo(b.tool['name'] as String));
  final matches = exact.isNotEmpty ? exact.take(1).toList() : ranked.map((entry) => entry.tool).toList();
  final selected = matches.skip(offset).take(limit).toList();
  final remaining = (matches.length - offset - selected.length).clamp(0, matches.length);
  return {
    'items': [for (final tool in selected) {
      'path': toolExpression(tool['name'] as String),
      'description': tool['description'] ?? '',
      'signature': toolSignature(tool),
    }],
    'remaining': remaining,
    'next': remaining == 0 ? null : {'offset': offset + selected.length},
  };
}
