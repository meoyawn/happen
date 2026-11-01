import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';

/// Lightweight warm task snapshots, independent of agent and SQLite owners.
/// Revalidate all candidate files at model boundaries, including missing overrides.
class RepositoryInstructions {
  final _snapshots = <String, Json>{};
  final _signatures = <String, String>{};

  Future<Json> load(String taskId, String cwd, CancellationToken cancellation) async {
    cancellation.throwIfCancelled();
    final previous = _snapshots.remove(taskId);
    final previousSignature = _signatures.remove(taskId);
    final directories = await _directories(cwd, cancellation);
    final signature = await _signature(directories, cancellation);
    if (previous != null && previous['cwd'] == cwd && previousSignature == signature) {
      _snapshots[taskId] = previous;
      _signatures[taskId] = signature;
      return previous;
    }
    // Discard the old selection before discovery, including on cancellation.
    final current = await _discover(cwd, directories, cancellation);
    cancellation.throwIfCancelled();
    _snapshots[taskId] = current;
    _signatures[taskId] = signature;
    // Evicted tasks resume cold. Idle snapshots never retain execution owners.
    while (_snapshots.length > 256) {
      forget(_snapshots.keys.first);
    }
    return current;
  }

  void forget(String taskId) {
    _snapshots.remove(taskId);
    _signatures.remove(taskId);
  }
}

Future<List<Directory>> _directories(String cwd, CancellationToken cancellation) async {
  final current = Directory(cwd);
  final chain = <Directory>[];
  var cursor = current;
  var foundRoot = false;
  while (true) {
    cancellation.throwIfCancelled();
    chain.add(cursor);
    final marker = await FileSystemEntity.type('${cursor.path}/.git');
    cancellation.throwIfCancelled();
    if (marker == FileSystemEntityType.file || marker == FileSystemEntityType.directory) {
      foundRoot = true;
      break;
    }
    if (cursor.parent.path == cursor.path) break;
    cursor = cursor.parent;
  }
  return foundRoot ? chain.reversed.toList() : [current];
}

Future<String> _signature(List<Directory> directories, CancellationToken cancellation) async {
  final files = <Object?>[];
  for (final directory in directories) {
    for (final name in ['AGENTS.override.md', 'AGENTS.md']) {
      cancellation.throwIfCancelled();
      final path = '${directory.path}/$name';
      // stat follows symlinks. ctime detects replacements and same-size edits
      // even when an editor preserves mtime; missing files detect later additions.
      final stat = await FileStat.stat(path);
      files.add([path, stat.type.toString(), stat.size, stat.mode,
        stat.modified.microsecondsSinceEpoch, stat.changed.microsecondsSinceEpoch]);
    }
  }
  cancellation.throwIfCancelled();
  return jsonEncode(files);
}

Future<Json> _discover(String cwd, List<Directory> directories, CancellationToken cancellation) async {
  final files = <Json>[];
  var remaining = 32768;
  var truncated = false;
  for (final directory in directories) {
    cancellation.throwIfCancelled();
    for (final name in ['AGENTS.override.md', 'AGENTS.md']) {
      final file = File('${directory.path}/$name');
      if (await FileSystemEntity.type(file.path) != FileSystemEntityType.file) {
        cancellation.throwIfCancelled();
        continue;
      }
      cancellation.throwIfCancelled();
      final bytes = <int>[];
      final chunks = StreamIterator(file.openRead(0, remaining + 1));
      try {
        while (await chunks.moveNext().asCancellable(
          cancellation,
          onCancel: () => unawaited(chunks.cancel()),
        )) {
          bytes.addAll(chunks.current);
        }
      } finally {
        await chunks.cancel();
      }
      cancellation.throwIfCancelled();
      final cut = bytes.length > remaining;
      final text = utf8.decode(bytes.take(remaining).toList(), allowMalformed: true);
      if (text.trim().isNotEmpty) {
        files.add({
          'path': file.path,
          'scope': directory.path,
          'text': text,
          if (cut) 'truncated': true,
        });
        remaining -= bytes.length.clamp(0, remaining);
      }
      truncated |= cut;
      // Selection is by filename, even when the preferred file is empty.
      break;
    }
    if (remaining == 0) {
      truncated = true;
      break;
    }
  }
  cancellation.throwIfCancelled();
  return {'cwd': cwd, 'files': files, 'truncated': truncated};
}
