import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:json_schema/json_schema.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'src/schema.dart';
export 'src/schema.dart' show globalConfigSchema;
export 'src/watcher.dart' show ConfigWatcher;

typedef ConfigSnapshot = ({String? path, Map<String, dynamic> values});

const _maxBytes = 1024 * 1024;
final _schema = JsonSchema.create(globalConfigSchema);

/// Configuration has its own home; moving it does not move credentials/history.
String defaultConfigPath() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    throw StateError('Cannot locate the home directory; pass --config PATH');
  }
  return p.join(home, '.happen', 'config.yaml');
}

/// Parses one YAML document into immutable plain Dart data. Never includes
/// source text or rejected values in errors: env/headers can contain credentials.
Map<String, dynamic> parseConfig(String source) {
  if (utf8.encode(source).length > _maxBytes) {
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
  final errors = _schema.validate(value).errors;
  if (errors.isNotEmpty) {
    final error = errors.first;
    final location = error.instancePath.isEmpty ? '/' : error.instancePath;
    final reason = error.message.startsWith('type:')
        ? 'incorrect value type'
        : error.message.startsWith('enum violated')
        ? 'unsupported option'
        : switch (error.schemaPath.split('/').last) {
            'additionalProperties' => 'unsupported field',
            'oneOf' => 'specify exactly one command or URL',
            'dependencies' => 'field does not apply to this transport',
            'maxProperties' => 'at most 64 MCP servers are supported',
            'minLength' || 'pattern' => 'invalid or empty string',
            'format' => 'invalid URI',
            _ => 'schema constraint failed',
          };
    throw FormatException('Invalid configuration at $location: $reason');
  }
  final config = value as Map<String, dynamic>;
  final names = <String>{};
  for (final entry in (config['mcp_servers'] as Map? ?? {}).entries) {
    final name = entry.key as String;
    if (!names.add(name.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_'))) {
      throw const FormatException(
        'MCP server names collide after normalization',
      );
    }
    final server = entry.value as Map;
    if (server['url'] case final String url) _validateUrl(url, 'MCP URL');
  }
  if (config['public_url'] case final String url) {
    _validateUrl(url, 'public_url');
  }
  return config;
}

void _validateUrl(String value, String field) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.port < 1 ||
      uri.port > 65535) {
    throw FormatException(
      '$field must be an HTTP(S) URL without credentials or a fragment',
    );
  }
}

/// YAML takes precedence; only a missing YAML file permits the legacy fallback.
/// Missing configuration returns an empty snapshot with a null path.
Future<ConfigSnapshot> loadConfig(
  String path, {
  String? legacyPath,
  CancellationToken? cancellation,
}) async {
  for (final candidate in [path, ?legacyPath]) {
    cancellation?.throwIfCancelled();
    try {
      return (
        path: candidate,
        values: parseConfig(await _read(File(candidate), cancellation)),
      );
    } on PathNotFoundException {
      continue;
    } on FormatException catch (error) {
      throw FormatException('$candidate: ${error.message}');
    }
  }
  return (path: null, values: const <String, dynamic>{});
}

Future<String> _read(File file, CancellationToken? cancellation) async {
  cancellation?.throwIfCancelled();
  final bytes = BytesBuilder(copy: false);
  StreamSubscription<List<int>>? subscription;
  final result = CancellableCompleter<void>(
    cancellation,
    onCancel: () => unawaited(subscription?.cancel()),
  );
  subscription = file
      .openRead(0, _maxBytes + 1)
      .listen(
        bytes.add,
        onError: result.completeError,
        onDone: result.complete,
        cancelOnError: true,
      );
  try {
    await result.future;
    cancellation?.throwIfCancelled();
    if (bytes.length > _maxBytes) {
      throw const FormatException('Configuration exceeds 1 MiB');
    }
    try {
      return utf8.decode(bytes.takeBytes());
    } on FormatException {
      throw const FormatException('Configuration must be UTF-8');
    }
  } finally {
    await subscription.cancel();
  }
}
