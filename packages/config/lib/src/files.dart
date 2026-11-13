part of '../config.dart';

typedef ConfigSnapshot = ({String? path, Map<String, dynamic> values});

/// Configuration has its own home; moving it does not move credentials/history.
String defaultConfigPath() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    throw StateError('Cannot locate the home directory; pass --config PATH');
  }
  return p.join(home, '.config', 'happen', 'config.yaml');
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
        validateMcpServers(Map<String, dynamic>.from(values['mcp_servers'] as Map? ?? {}));
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

/// Validate effective server identities and usable network addresses.
void validateMcpServers(Map<String, dynamic> servers) {
  final names = <String>{};
  for (final entry in servers.entries) {
    if (!names.add(entry.key.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_'))) {
      throw const FormatException('MCP server names collide after normalization');
    }
    if ((entry.value as Map)['url'] case final String value) {
      final uri = Uri.tryParse(value);
      if (uri == null || !{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty ||
          uri.userInfo.isNotEmpty || uri.hasFragment || uri.port < 1 || uri.port > 65535) {
        throw const FormatException('MCP URL must be an HTTP(S) URL without credentials or a fragment');
      }
    }
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

String _expandHomePath(String value) {
  if (value != '~' && !value.startsWith('~/') && !(Platform.isWindows && value.startsWith('~\\'))) return value;
  final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) throw const FormatException('Cannot resolve ~ without a home directory');
  return p.normalize(p.join(home, value == '~' ? '' : value.substring(2)));
}

Map<String, dynamic> resolveMcpPaths(Map<String, dynamic> servers, {required String base, String? defaultCwd}) => {
  for (final entry in servers.entries) entry.key: {
    ...entry.value as Map,
    if (entry.value['command'] case final String command) 'command': _expandHomePath(command),
    if (entry.value['cwd'] != null || entry.value['command'] != null && defaultCwd != null)
      'cwd': p.normalize(p.absolute(p.join(base, _expandHomePath(entry.value['cwd'] as String? ?? defaultCwd!)))),
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
      .openRead(0, _maxConfigBytes + 1)
      .listen(
        bytes.add,
        onError: result.completeError,
        onDone: result.complete,
        cancelOnError: true,
      );
  try {
    await result.future;
    cancellation?.throwIfCancelled();
    if (bytes.length > _maxConfigBytes) {
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
