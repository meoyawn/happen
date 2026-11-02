import 'dart:convert';

import 'package:protocol/protocol.dart';
import 'package:schema_engine/schema_engine.dart';

// Content keys notice schema edits, even when a caller reuses the same map.
// Bound the LRU so replaced tool catalogs cannot retain validators forever.
final _toolSchemas = <String, CompiledSchema>{};

void validateToolInput(Object? value, Json schema, String path) {
  final key = jsonEncode(schema);
  var validator = _toolSchemas.remove(key);
  if (validator == null) {
    try {
      // Synchronous compilation resolves local refs only; never fetch tool data.
      validator = JsonSchema.fromJson(schema).compile();
    } on SchemaException catch (error) {
      throw FormatException('Invalid $path schema at ${error.schemaPath}');
    } on ReferenceException {
      throw FormatException('Unresolved reference in $path schema');
    } on FormatException {
      throw FormatException('Invalid $path schema');
    }
    if (_toolSchemas.length >= 128) _toolSchemas.remove(_toolSchemas.keys.first);
  }
  _toolSchemas[key] = validator;
  final error = validator.validate(value);
  if (error != null) {
    final location = error.instancePath.isEmpty ? '/' : error.instancePath;
    throw FormatException('Invalid $path at $location: ${error.keyword} constraint failed');
  }
}
