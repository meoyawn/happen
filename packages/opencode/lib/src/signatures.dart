import 'dart:convert';

import 'package:protocol/protocol.dart';

Json _object(Object? value) => value is Map ? jsonObject(value) : const {};

// Model-visible JSON Schema rendering from @opencode/codemode/tool-schema.ts.
final _identifier = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');
String _key(String name) => _identifier.hasMatch(name) ? name : jsonEncode(name);
String toolExpression(String path) => 'tools${path.split('.').map((part) =>
  _identifier.hasMatch(part) ? '.$part' : '[${jsonEncode(part)}]').join()}';

String toolSignature(Json tool) {
  final input = schemaType(_object(tool['parameters']));
  final output = tool.containsKey('output_schema') ? schemaType(_object(tool['output_schema'])) : 'unknown';
  return '${toolExpression(tool['name'] as String)}(${input == '{}' ? '' : input}): Promise<$output>';
}

String? _definition(String reference) {
  List<String> parts;
  try { parts = Uri.decodeComponent(reference).split('/'); } on FormatException { return null; }
  if (parts.length != 3 || parts[0] != '#' || ![r'$defs', 'definitions'].contains(parts[1])) return null;
  return parts[2].replaceAll('~1', '/').replaceAll('~0', '~');
}

Json schemaProperties(Json schema) {
  if (schema[r'$ref'] case final String ref) {
    final definitions = {..._object(schema['definitions']), ..._object(schema[r'$defs'])};
    schema = _object(definitions[_definition(ref)]);
  }
  return _object(schema['properties']);
}

String _intersection(Iterable<String> members) {
  final concrete = members.where((member) => member != 'unknown').toList();
  if (concrete.isEmpty) return 'unknown';
  if (concrete.length == 1) return concrete.single;
  return concrete.map((member) => member.contains(' | ') ? '($member)' : member).join(' & ');
}

List<String> _docLines(Json schema, int width) {
  final tags = <String>[
    if (schema['deprecated'] == true) '@deprecated',
    if (schema.containsKey('default')) '@default ${jsonEncode(schema['default'])}',
    if (schema['format'] is String) '@format ${schema['format']}',
    if (schema['type'] == 'integer') '@integer',
    for (final key in ['minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum',
      'multipleOf', 'minLength', 'maxLength', 'pattern', 'minItems', 'maxItems'])
      if (schema.containsKey(key) && !(schema['type'] == 'integer' &&
        (key == 'minimum' && schema[key] == -9007199254740991 || key == 'maximum' && schema[key] == 9007199254740991)))
        '@$key ${schema[key]}',
    if (schema['uniqueItems'] == true) '@uniqueItems true',
  ];
  final summary = tags.join(' ');
  final lines = (schema['description'] as String? ?? '').split('\n').map((line) => line.trimRight()).toList();
  while (lines.isNotEmpty && lines.first.trim().isEmpty) { lines.removeAt(0); }
  while (lines.isNotEmpty && lines.last.trim().isEmpty) { lines.removeLast(); }
  final inline = lines.length == 1 ? '${lines.single}${lines.single.endsWith('.') ? '' : '.'} $summary' : summary;
  return summary.isNotEmpty && lines.length == 1 && !summary.contains('\n') && width + inline.length + 7 <= 120
    ? [inline] : [...lines, if (summary.isNotEmpty) ...summary.split('\n')];
}

String _docs(Json schema, String pad) {
  final content = _docLines(schema, pad.length);
  final type = schema['type'];
  final types = type is List ? type : [type];
  void append(String label, Json child) {
    final lines = _docLines(child, pad.length + label.length + 2);
    for (var i = 0; i < lines.length; i++) {
      content.add(i == 0 ? '$label: ${lines[i]}' : lines[i].isEmpty ? '' : '  ${lines[i]}');
    }
  }
  if (types.contains('array') && schema['items'] is Map) append('Each item', _object(schema['items']));
  if ((types.contains('object') || schema['properties'] is Map) && schema['additionalProperties'] is Map) {
    append(_object(schema['properties']).isNotEmpty ? 'Each additional value' : 'Each value', _object(schema['additionalProperties']));
  }
  if (content.isEmpty) return '';
  final escaped = content.map((line) => line.replaceAll('*/', '* /')).toList();
  if (escaped.length == 1 && pad.length + escaped.single.length + 7 <= 120) return '$pad/** ${escaped.single} */\n';
  return '$pad/**\n${escaped.map((line) => '$pad *${line.isEmpty ? '' : ' $line'}').join('\n')}\n$pad */\n';
}

bool _unresolved(Json schema, Json definitions, [Set<String> seen = const {}]) {
  if (schema[r'$ref'] case final String reference) {
    final name = _definition(reference);
    if (name == null || !definitions.containsKey(name) || seen.contains(name)) return true;
    if (_unresolved(_object(definitions[name]), definitions, {...seen, name})) return true;
  }
  final children = <Object?>[
    for (final key in ['anyOf', 'oneOf', 'allOf']) ...schema[key] as List? ?? [],
    ..._object(schema['properties']).values,
    if (schema['items'] is Map) schema['items'],
    if (schema['additionalProperties'] is Map) schema['additionalProperties'],
  ];
  return children.any((child) => _unresolved(_object(child), definitions, seen));
}

String schemaType(Json schema, {bool pretty = true}) {
  try { return _render(schema, const {}, pretty); } catch (_) { return 'unknown'; }
}

String _render(Json schema, Json definitions, bool pretty, [int depth = 0, Set<String> seen = const {}]) {
  if (depth > 8) return 'unknown';
  final nested = {...definitions, ..._object(schema['definitions']), ..._object(schema[r'$defs'])};
  String render(Json value, [Set<String>? references]) => _render(value, nested, pretty, depth + 1, references ?? seen);
  Json without(List<String> keys) => {...schema}..removeWhere((key, _) => keys.contains(key));
  if (schema[r'$ref'] case final String reference) {
    final name = _definition(reference);
    if (name == null || !nested.containsKey(name) || seen.contains(name)) return 'unknown';
    return _intersection([_render(_object(nested[name]), nested, pretty, depth, {...seen, name}), render(without([r'$ref']))]);
  }
  if (schema.containsKey('const')) return jsonEncode(schema['const']);
  if (schema['enum'] case final List values) return values.map(jsonEncode).join(' | ');
  final listed = schema['anyOf'] ?? schema['oneOf'];
  if (listed is List) {
    bool sentinel(dynamic value) => value['type'] == 'string' && value['enum'] is List &&
      (value['enum'] as List).isNotEmpty && (value['enum'] as List).every(['NaN', 'Infinity', '-Infinity'].contains);
    final alternatives = listed.any((value) => value['type'] == 'number') ? listed.where((value) => !sentinel(value)).toList() : listed;
    if (alternatives.any((value) => value['type'] == 'number') &&
      alternatives.every((value) => value['type'] == 'number' || sentinel(value))) { return 'number'; }
    if (alternatives.length == 2 && alternatives[0]['type'] == 'object' && alternatives[0]['properties'] == null &&
      alternatives[1]['type'] == 'array' && alternatives[1]['items'] == null) { return '{}'; }
    final members = alternatives.map((value) => render(_object(value))).toList();
    if (members.contains('unknown')) return 'unknown';
    return _intersection([members.join(' | '), render(without(['anyOf', 'oneOf']))]);
  }
  if (schema['allOf'] case final List members) {
    if (members.any((value) => _unresolved(_object(value), nested))) return 'unknown';
    return _intersection([render(without(['allOf'])), ...members.map((value) => render(_object(value)))]);
  }
  if (schema['type'] case final List types) return types.map((type) => render({...schema, 'type': type})).join(' | ');
  switch (schema['type']) {
    case 'string': return 'string';
    case 'number':
    case 'integer': return 'number';
    case 'boolean': return 'boolean';
    case 'null': return 'null';
    case 'array': return 'Array<${render(_object(schema['items']))}>';
  }
  if (schema['type'] == 'object' || schema['properties'] is Map) {
    final properties = _object(schema['properties']), required = (schema['required'] as List? ?? []).toSet();
    final additional = schema['additionalProperties'];
    final indexType = additional is Map ? render(_object(additional)) : null;
    String field(MapEntry<String, dynamic> entry) => '${_key(entry.key)}${required.contains(entry.key) ? '' : '?'}: ${render(_object(entry.value))}';
    if (!pretty) {
      final fields = [...properties.entries.map(field), if (indexType != null) '[key: string]: $indexType'];
      return fields.isEmpty ? '{}' : '{ ${fields.join('; ')} }';
    }
    if (properties.isEmpty && indexType == null) return '{}';
    final pad = '  ' * (depth + 1);
    final lines = [for (final entry in properties.entries) '${_docs(_object(entry.value), pad)}$pad${field(entry)},',
      if (indexType != null) '$pad[key: string]: $indexType,'];
    return '{\n${lines.join('\n')}\n${'  ' * depth}}';
  }
  if (schema['not'] is Map && _object(schema['not']).length == 1 && schema['not']['type'] == 'null' &&
    schema.keys.every(['not', 'title', 'description', 'default', 'examples', 'readOnly', 'writeOnly'].contains)) { return '{}'; }
  return 'unknown';
}
