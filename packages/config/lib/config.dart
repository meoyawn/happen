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
export 'src/executables.dart' show McpExecutable, readMcpExecutables;

typedef ConfigSnapshot = ({String? path, Map<String, dynamic> values});

const _maxBytes = 1024 * 1024;
final _configValidator = JsonSchema.fromJson(globalConfigSchema)
    .compile(options: SchemaOptions(assertFormats: true));
final _localMcpValidator = () {
  final properties = globalConfigSchema['properties']! as Map<String, Object?>;
  final mcp = properties['mcp_servers']! as Map<String, Object?>;
  final server = Map<String, Object?>.of(mcp['additionalProperties']! as Map<String, Object?>)
    ..remove('oneOf')..remove('dependencies');
  return JsonSchema.fromJson({...globalConfigSchema, 'properties': {
    ...properties, 'mcp_servers': {...mcp, 'additionalProperties': server},
  }}).compile(options: SchemaOptions(assertFormats: true));
}();

/// Configuration has its own home; moving it does not move credentials/history.
String defaultConfigPath() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    throw StateError('Cannot locate the home directory; pass --config PATH');
  }
  return p.join(home, '.config', 'happen', 'config.yaml');
}

/// Parses one YAML document into immutable plain Dart data. `code_mode_only`
/// accepts a boolean; OpenAI defaults to true when it is omitted. Never includes
/// source text or rejected values in errors: env/headers can contain credentials.
Map<String, dynamic> parseConfig(String source, {bool partialMcp = false}) {
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
}) => ConfigReader().load(path, legacyPath: legacyPath, cancellation: cancellation);

/// A config owner rechecks bytes on every read, but parses/validates only edits.
/// Content equality also detects same-size edits with preserved timestamps and
/// edits made by a tool before the filesystem watcher's debounce has fired.
class ConfigReader {
  ConfigReader({this.partialMcp = false});
  final bool partialMcp;
  String? _path, _source;
  Map<String, dynamic>? _values;

  Future<ConfigSnapshot> load(String path, {
    String? legacyPath,
    CancellationToken? cancellation,
  }) async {
    for (final candidate in [path, ?legacyPath]) {
      cancellation?.throwIfCancelled();
      try {
        final source = await _read(File(candidate), cancellation);
        cancellation?.throwIfCancelled();
        if (_path == candidate && _source == source) return (path: candidate, values: _values!);
        final values = parseConfig(source, partialMcp: partialMcp);
        _path = candidate; _source = source; _values = values;
        return (path: candidate, values: values);
      } on PathNotFoundException {
        continue;
      } on FormatException catch (error) {
        throw FormatException('$candidate: ${error.message}');
      }
    }
    _path = null; _source = null; _values = null;
    return (path: null, values: const <String, dynamic>{});
  }
}

/// Codex config/loader/mod.rs::discover_project_layers, adapted to Happen YAML.
/// Repository layers run from the checkout root to cwd, with the closest last.
Future<List<String>> mcpConfigPaths(String cwd, CancellationToken cancellation) async {
  // Walk the selected physical checkout. A lexical ancestor of a directory
  // symlink need not be an ancestor of the working directory and must not gain
  // authority to launch project MCPs for that target.
  final current = Directory(await Directory(p.normalize(p.absolute(cwd))).resolveSymbolicLinks()), chain = <Directory>[];
  var cursor = current, repository = false;
  while (true) {
    cancellation.throwIfCancelled(); chain.add(cursor);
    final type = await FileSystemEntity.type('${cursor.path}/.git');
    if (type == FileSystemEntityType.file || type == FileSystemEntityType.directory) { repository = true; break; }
    if (cursor.parent.path == cursor.path) break;
    cursor = cursor.parent;
  }
  cancellation.throwIfCancelled();
  return [for (final dir in repository ? chain.reversed : [current]) p.join(dir.path, '.happen', 'config.yaml')];
}

/// Codex config/merge.rs: tables merge recursively; arrays/scalars replace.
Map<String, dynamic> mergeMcpConfig(Map<String, dynamic> base, Map<String, dynamic> overlay) => {
  ...base,
  for (final entry in overlay.entries) entry.key: base[entry.key] is Map && entry.value is Map
    ? mergeMcpConfig(Map<String, dynamic>.from(base[entry.key] as Map), Map<String, dynamic>.from(entry.value as Map)) : entry.value,
};

Map<String, dynamic> resolveMcpCwds(Map<String, dynamic> servers, {required String base, String? defaultCwd}) => {
  for (final entry in servers.entries) entry.key: {
    ...entry.value as Map,
    if (entry.value['cwd'] != null || entry.value['command'] != null && defaultCwd != null)
      'cwd': p.normalize(p.absolute(p.join(base, entry.value['cwd'] as String? ?? defaultCwd!))),
  },
};

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
