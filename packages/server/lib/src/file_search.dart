import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:protocol/protocol.dart';

const _maxIndexBytes = 8 * 1024 * 1024;
const _maxFiles = 100000;
const _indexLifetime = Duration(seconds: 10);
typedef _Index = ({List<String> paths, bool truncated, DateTime created});
typedef _Match = ({String path, int score, bool directory});

/// Bounded file and directory names. No watchers, contents, or client indexes.
class FileSearch {
  final _indexes = <String, _Index>{};

  Future<Json> search(Json params, CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    final cwd = requiredString(params, 'cwd');
    final query = params['query'];
    final limit = params['limit'] ?? 20;
    if (!Directory(cwd).isAbsolute || cwd.contains('\x00')) {
      throw const FormatException('cwd must be an absolute directory');
    }
    if (query is! String || query.length > 256 || query.contains(RegExp(r'[\x00-\x1f]'))) {
      throw const FormatException('query must be a string of at most 256 characters');
    }
    if (limit is! int || limit < 1 || limit > 50) {
      throw const FormatException('limit must be 1..50');
    }
    if (!await Directory(cwd).exists()) {
      throw const FileSystemException('Search directory is unavailable');
    }
    cancellation.throwIfCancelled();
    var index = _indexes.remove(cwd);
    if (index == null || DateTime.now().difference(index.created) >= _indexLifetime) {
      index = await _scan(cwd, cancellation);
    }
    cancellation.throwIfCancelled();
    _indexes[cwd] = index;
    while (_indexes.length > 4) {
      _indexes.remove(_indexes.keys.first);
    }

    final needle = query.toLowerCase().replaceAll('\\', '/').replaceFirst(RegExp(r'^\./'), '');
    final matches = <_Match>[];
    var count = 0;
    for (var i = 0; i < index.paths.length; i++) {
      // Yield to WebSocket replies and task streams, including on cached searches.
      if (i % 1024 == 0) await cancellableDelay(Duration.zero, cancellation);
      final path = index.paths[i];
      final score = _score(path, needle);
      if (score == null) continue;
      count++;
      // Files and folders share one ranking; classify only entries that can fit.
      if (matches.length == limit &&
          _compare((path: path, score: score, directory: false), matches.last) >= 0) {
        continue;
      }
      // Cached entries may have disappeared; Git can also return submodule roots.
      final type = await FileSystemEntity.type('$cwd/$path');
      if (type != FileSystemEntityType.file && type != FileSystemEntityType.directory) continue;
      cancellation.throwIfCancelled();
      final directory = type == FileSystemEntityType.directory;
      final match = (path: path, score: score, directory: directory);
      _keep(matches, match, limit);
    }
    final paths = <String>[];
    var bytes = 0;
    var truncated = index.truncated || count > limit;
    for (final match in matches) {
      cancellation.throwIfCancelled();
      final path = match.directory ? '${match.path}/' : match.path;
      bytes += utf8.encode(jsonEncode(path)).length;
      if (bytes > 32 * 1024) {
        truncated = true;
        break;
      }
      paths.add(path);
    }
    cancellation.throwIfCancelled();
    return {'paths': paths, 'truncated': truncated};
  }

  void clear() => _indexes.clear();
}

int _compare(_Match a, _Match b) {
  final score = b.score.compareTo(a.score);
  if (score != 0) return score;
  final length = a.path.length.compareTo(b.path.length);
  return length == 0 ? a.path.compareTo(b.path) : length;
}

void _keep(List<_Match> matches, _Match match, int limit) {
  var at = 0;
  while (at < matches.length && _compare(matches[at], match) < 0) { at++; }
  if (at >= limit) return;
  matches.insert(at, match);
  if (matches.length > limit) matches.removeLast();
}

// Explicit paths stay scoped to the folder selected with Tab.
int? _score(String path, String query) {
  final lower = path.toLowerCase();
  final basename = lower.substring(lower.lastIndexOf('/') + 1);
  if (query.isEmpty) return -path.length;
  final name = query.replaceFirst(RegExp(r'/$'), '');
  if (query.contains('/')) {
    if (lower == name) return query.endsWith('/') ? null : 100000 - path.length;
    if (lower.startsWith(query)) return 60000 - path.length;
    if (lower.contains('/$query')) return 20000 - path.length;
    return null;
  }
  if (lower == name || basename == name) return 100000 - basename.length;
  if (basename.startsWith(query)) return 80000 - basename.length;
  if (lower.startsWith(query)) return 60000 - path.length;
  if (basename.contains(query)) return 40000 - basename.length;
  if (lower.contains(query)) return 20000 - path.length;
  var position = 0, gaps = 0, previous = -1;
  for (final unit in query.codeUnits) {
    final found = lower.indexOf(String.fromCharCode(unit), position);
    if (found < 0) return null;
    if (previous >= 0) gaps += found - previous - 1;
    previous = found;
    position = found + 1;
  }
  return 10000 - gaps * 10 - path.length;
}

Future<_Index> _scan(String cwd, CancellationToken cancellation) async {
  final base = await _gitNames(cwd, ['--cached', '--others', '--exclude-standard'], cancellation);
  if (base == null) return _walk(cwd, cancellation);
  // The regular listing keeps untracked files and uninitialized gitlinks.
  // Recursive cached mode contributes tracked files inside initialized submodules.
  final nested = await _gitNames(cwd, ['--cached', '--recurse-submodules'], cancellation);
  final paths = <String>{};
  var pathBytes = 0;
  final names = [...base.names, ...?nested?.names];
  for (var i = 0; i < names.length; i++) {
    if (i % 1024 == 0) await cancellableDelay(Duration.zero, cancellation);
    final name = names[i];
    if (!_usablePath(name)) continue;
    // Gitlinks and derived parent folders share one slash-free index key.
    // Directory suffixes are added only after filesystem classification.
    var path = name.endsWith('/') ? name.substring(0, name.length - 1) : name;
    // Deriving parents preserves Git's ignore rules without a second walk.
    while (path.isNotEmpty && !paths.contains(path)) {
      pathBytes += utf8.encode(path).length;
      if (paths.length == _maxFiles || pathBytes > _maxIndexBytes) {
        return (paths: paths.toList(), truncated: true, created: DateTime.now());
      }
      paths.add(path);
      final slash = path.lastIndexOf('/');
      path = slash < 0 ? '' : path.substring(0, slash);
    }
  }
  return (paths: paths.toList(), truncated: base.truncated || (nested?.truncated ?? false), created: DateTime.now());
}

Future<({List<String> names, bool truncated})?> _gitNames(
    String cwd, List<String> options, CancellationToken cancellation) async {
  cancellation.throwIfCancelled();
  Process? process;
  try {
    process = await Process.start('git', ['-C', cwd, 'ls-files', '-z', ...options]);
  } on ProcessException {
    // Plain folders remain usable on hosts without Git.
  }
  if (process == null) return null;
  final running = process;
  if (cancellation.isCancelled) {
    running.kill(ProcessSignal.sigkill);
    await Future.wait<Object?>([running.stdout.drain<void>(), running.stderr.drain<void>(), running.exitCode]);
    cancellation.throwIfCancelled();
  }
  final hook = CancellationHook(cancellation, () => running.kill(ProcessSignal.sigkill));
  final errors = running.stderr.drain<void>();
  final output = ownStream(running.stdout, cancellation);
  final bytes = BytesBuilder(copy: false);
  var truncated = false;
  try {
    cancellation.throwIfCancelled();
    await for (final chunk in output.stream) {
      cancellation.throwIfCancelled();
      final remaining = _maxIndexBytes - bytes.length;
      if (chunk.length > remaining) {
        bytes.add(chunk.sublist(0, remaining));
        truncated = true;
        running.kill(ProcessSignal.sigkill);
        break;
      }
      bytes.add(chunk);
    }
    final code = await running.exitCode;
    await errors;
    cancellation.throwIfCancelled();
    if (code != 0 && !truncated) return null;
    final names = utf8.decode(bytes.takeBytes(), allowMalformed: true).split('\x00');
    names.removeLast(); // A truncated final record is never a complete path.
    return (names: names, truncated: truncated);
  } finally {
    hook.dispose();
    running.kill(ProcessSignal.sigkill);
    await output.close();
    await running.exitCode;
    await errors;
  }
}

bool _usablePath(String path) => path.isNotEmpty &&
    path.length <= 4096 &&
    !path.startsWith('/') &&
    !path.split('/').any((part) => part == '..' || part == '.git') &&
    !path.contains(RegExp(r'[\x00-\x1f\x7f]'));

Future<_Index> _walk(String cwd, CancellationToken cancellation) async {
  final paths = <String>[];
  final directories = <String>[''];
  var bytes = 0, visited = 0, truncated = false;
  while (directories.isNotEmpty) {
    cancellation.throwIfCancelled();
    final relative = directories.removeLast();
    final listing = ownStream(Directory('$cwd/$relative').list(followLinks: false), cancellation);
    try {
      await for (final entry in listing.stream) {
        cancellation.throwIfCancelled();
        if (++visited > _maxFiles || bytes >= _maxIndexBytes) {
          return (paths: paths, truncated: true, created: DateTime.now());
        }
        final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
        final path = '$relative$name';
        if (!_usablePath(path)) continue;
        if (entry is Directory) {
          if ({'.git', '.hg', '.svn', 'node_modules', '.dart_tool', 'build', '.cache'}.contains(name)) continue;
          directories.add('$path/');
        } else if (entry is! File) {
          continue;
        }
        final length = utf8.encode(path).length;
        if (bytes + length > _maxIndexBytes) {
          return (paths: paths, truncated: true, created: DateTime.now());
        }
        paths.add(path);
        bytes += length;
      }
    } on FileSystemException {
      truncated = true; // A disappearing/unreadable child need not hide other files.
    } finally {
      await listing.close();
    }
  }
  return (paths: paths, truncated: truncated, created: DateTime.now());
}
