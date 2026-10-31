import 'dart:convert';

import 'package:protocol/protocol.dart';

/// Documentation for the JavaScript host proxy. Keep the original JSON schema
/// alongside it: TypeScript cannot express every JSON Schema constraint.
Json describeHostTool(Json tool) {
  final name = tool['name'] as String;
  final parameters = jsonObject(tool['parameters'] ?? {});
  final target = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$').hasMatch(name)
      ? 'tools.$name' : 'tools[${jsonEncode(name)}]';
  final input = tool['format'] == 'text' ? 'string' : _type(parameters);
  return {
    ...tool,
    'description': '${tool['description'] ?? ''}\n\n'
      'Declaration: $target(args: $input): Promise<unknown>;',
  };
}

String _type(Object? value, [int depth = 0]) {
  if (value == false) return 'never';
  if (value is! Map || depth > 12) return 'unknown';
  if (value.containsKey('const')) return jsonEncode(value['const']);
  if (value['enum'] is List) {
    final values = value['enum'] as List;
    return values.isEmpty ? 'never' : values.map(jsonEncode).join(' | ');
  }
  for (final key in ['anyOf', 'oneOf', 'allOf']) {
    if (value[key] is List) {
      return (value[key] as List).map((part) => '(${_type(part, depth + 1)})')
          .join(key == 'allOf' ? ' & ' : ' | ');
    }
  }
  final type = value['type'];
  if (type is List) {
    return type.map((type) => _type({...value, 'type': type}, depth + 1)).join(' | ');
  }
  switch (type) {
    case 'string': return 'string';
    case 'integer':
    case 'number': return 'number';
    case 'boolean': return 'boolean';
    case 'null': return 'null';
    case 'array': return 'Array<${_type(value['items'], depth + 1)}>';
    case 'object':
      final required = (value['required'] as List? ?? []).toSet();
      final properties = jsonObject(value['properties'] ?? {});
      final fields = [
        for (final entry in properties.entries)
          '${jsonEncode(entry.key)}${required.contains(entry.key) ? '' : '?'}: ${_type(entry.value, depth + 1)};',
        if (value['additionalProperties'] != false)
          '[key: string]: unknown;',
      ];
      return '{ ${fields.join(' ')} }';
    default: return 'unknown';
  }
}
