import 'dart:convert';
import 'dart:io';

import 'package:cancellation_token/cancellation_token.dart';
import 'package:path/path.dart' as p;

typedef McpExecutable = ({List<String> paths, String revision});

/// Resolve local commands and retain both launch paths and symlink targets.
/// File metadata detects rebuilds without reading large binaries on every poll.
Future<Map<String, McpExecutable>> readMcpExecutables(
  Map<String, dynamic> servers,
  CancellationToken cancellation,
) async {
  final result = <String, McpExecutable>{};
  for (final entry in servers.entries) {
    cancellation.throwIfCancelled();
    final server = entry.value as Map;
    if (server['enabled'] == false || server['command'] is! String) continue;
    final command = server['command'] as String;
    final cwd = p.absolute(server['cwd'] as String? ?? Directory.current.path);
    final searchPath = (server['env'] as Map?)?['PATH'] as String? ??
        Platform.environment['PATH'] ?? '';
    final candidates = p.isAbsolute(command) || p.split(command).length > 1
        ? [p.normalize(p.join(cwd, command))]
        : [
            for (final directory in searchPath.split(Platform.isWindows ? ';' : ':'))
              p.normalize(p.join(cwd, directory, command)),
          ];
    final paths = <String>[];
    var revision = 'missing';
    for (final candidate in candidates) {
      cancellation.throwIfCancelled();
      paths.add(candidate);
      final stat = await File(candidate).stat();
      if (stat.type != FileSystemEntityType.file ||
          !Platform.isWindows && stat.mode & 0x49 == 0) {
        continue;
      }
      try {
        final resolved = await File(candidate).resolveSymbolicLinks();
        if (resolved != candidate) paths.add(resolved);
        revision = jsonEncode([
          candidate, resolved, stat.size, stat.mode,
          stat.modified.microsecondsSinceEpoch,
          stat.changed.microsecondsSinceEpoch,
        ]);
        break;
      } on FileSystemException {
        // An atomic replacement may race resolution; retry on the next poll.
      }
    }
    result[entry.key] = (paths: paths, revision: revision);
  }
  cancellation.throwIfCancelled();
  return result;
}
