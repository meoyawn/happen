import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:path/path.dart' as p;
import 'package:schema_engine/schema_engine.dart';
import 'package:yaml/yaml.dart';

import 'src/schema.dart';
export 'src/schema.dart' show globalConfigSchema;
export 'src/watcher.dart' show ConfigWatcher;

part 'src/files.dart';

const _maxConfigBytes = 1024 * 1024;
final _configValidator = JsonSchema.fromJson(globalConfigSchema)
    .compile(options: SchemaOptions(assertFormats: true));
final _localMcpValidator = JsonSchema.fromJson({
  ...globalConfigSchema,
  r'$ref': '#/definitions/project',
}).compile(options: SchemaOptions(assertFormats: true));

/// Parses one YAML document into immutable plain Dart data. Never includes
/// source text or rejected values in errors: env/headers can contain credentials.
Map<String, dynamic> parseConfig(String source, {bool partialMcp = false}) {
  if (utf8.encode(source).length > _maxConfigBytes) {
    throw const FormatException('Configuration exceeds 1 MiB');
  }
  final YamlNode root;
  try {
    root = loadYamlNode(source);
  } on YamlException catch (error) {
    final position = error.span?.start;
    throw FormatException(
      'Invalid YAML${position == null ? '' : ' at line ${position.line + 1}, column ${position.column + 1}'}',
    );
  }
  var remaining = 100000;
  Object? plain(YamlNode node, [int depth = 0]) {
    if (--remaining < 0 || depth > 64) {
      throw const FormatException(
        'Configuration is too deeply nested or large',
      );
    }
    if (node is YamlMap) {
      final result = <String, dynamic>{};
      for (final entry in node.nodes.entries) {
        if (entry.key.value is! String) {
          throw const FormatException('Configuration keys must be strings');
        }
        result[entry.key.value as String] = plain(entry.value, depth + 1);
      }
      return Map<String, dynamic>.unmodifiable({
        for (final key in result.keys.toList()..sort()) key: result[key],
      });
    }
    if (node is YamlList) {
      return List<Object?>.unmodifiable([
        for (final child in node.nodes) plain(child, depth + 1),
      ]);
    }
    final value = node.value;
    if (value is num && !value.isFinite) {
      throw const FormatException('Configuration numbers must be finite');
    }
    return value;
  }

  // Empty/comment-only files are empty config; an explicit YAML null is invalid.
  final empty =
      root.value == null &&
      (root.span.text.trim().isEmpty ||
          const LineSplitter()
              .convert(source)
              .every(
                (line) =>
                    line.trim().isEmpty || line.trimLeft().startsWith('#'),
              ));
  final value = empty ? const <String, dynamic>{} : plain(root);
  final error = (partialMcp ? _localMcpValidator : _configValidator).validate(value);
  if (error != null) {
    final location = error.instancePath.isEmpty ? '/' : error.instancePath;
    final reason = switch (error.keyword) {
      'type' => 'incorrect value type',
      'enum' => 'unsupported option',
      'additionalProperties' => 'unsupported field',
      'oneOf' => error.schemaPath.contains('/oauth/')
          ? 'specify OAuth options or false' : 'specify exactly one command or URL',
      'dependencies' => 'field does not apply to this transport',
      'maxProperties' => 'at most 64 MCP servers are supported',
      'minLength' || 'pattern' => 'invalid or empty string',
      'format' => 'invalid URI',
      _ => 'schema constraint failed',
    };
    throw FormatException('Invalid configuration at $location: $reason');
  }
  return value as Map<String, dynamic>;
}
