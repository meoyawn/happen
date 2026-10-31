import 'package:protocol/protocol.dart';

void validateToolInput(Object? value, Json schema, String path) {
  if (schema['enum'] case final List allowed) {
    if (!allowed.contains(value)) throw FormatException('Invalid $path');
  }
  if (value is num) {
    if (schema['minimum'] case final num minimum when value < minimum) throw FormatException('Invalid $path');
    if (schema['exclusiveMinimum'] case final num minimum when value <= minimum) throw FormatException('Invalid $path');
    if (schema['maximum'] case final num maximum when value > maximum) throw FormatException('Invalid $path');
  }
  switch (schema['type']) {
    case 'object':
      final object = jsonObject(value);
      final properties = jsonObject(schema['properties']);
      for (final key in schema['required'] as List? ?? []) {
        if (!object.containsKey(key)) throw FormatException('Missing $path.$key');
      }
      for (final entry in object.entries) {
        if (!properties.containsKey(entry.key)) {
          if (schema['additionalProperties'] == false) throw FormatException('Unsupported $path argument');
          continue;
        }
        validateToolInput(entry.value, jsonObject(properties[entry.key]), '$path.${entry.key}');
      }
    case 'number':
      if (value is! num || !value.isFinite) throw FormatException('Invalid $path');
    case 'boolean':
      if (value is! bool) throw FormatException('Invalid $path');
    case 'array':
      if (value is! List) throw FormatException('Invalid $path');
      for (final item in value) {
        validateToolInput(item, jsonObject(schema['items']), path);
      }
    case 'string':
      if (value is! String) throw FormatException('Invalid $path');
      if (value.length < (schema['minLength'] as int? ?? 0)) throw FormatException('Invalid $path');
    case 'integer':
      if (value is! int || value < (schema['minimum'] as num? ?? 0)) throw FormatException('Invalid $path');
  }
}

