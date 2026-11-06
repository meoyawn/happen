import 'dart:io';
import 'dart:convert';

import 'package:protocol/protocol.dart';

import 'diff.dart';

Future<String> applyPatch(String cwd, String patch, {required CancellationToken cancellation,
  String? callId, Future<void> Function(String phase, Json item)? onItem,
  Future<void> Function(Json delta)? onPatch}) async {
  cancellation.throwIfCancelled();
  if (patch.length > 1024 * 1024) {
    throw const FormatException('Patch exceeds 1 MiB');
  }
  final lines = patch
      .trimRight()
      .split('\n')
      .map((line) => line.replaceFirst(RegExp(r'\r$'), ''))
      .toList();
  if (lines.first != '*** Begin Patch' || lines.last != '*** End Patch') {
    throw const FormatException('Expected *** Begin Patch and *** End Patch');
  }
  final changes =
      <({String path, String? destination, String? content, String kind})>[];
  final nativeChanges = <String, dynamic>{};
  var i = 1;
  String resolve(String path) => File(path).isAbsolute ? path : '$cwd/$path';
  while (i < lines.length - 1) {
    cancellation.throwIfCancelled();
    final header = lines[i++];
    if (header.startsWith('*** Add File: ')) {
      final path = resolve(header.substring(14));
      final added = <String>[];
      while (i < lines.length && !lines[i].startsWith('*** ')) {
        if (!lines[i].startsWith('+')) {
          throw const FormatException('Added file lines must begin with +');
        }
        added.add(lines[i++].substring(1));
      }
      changes.add((
        path: path,
        destination: null,
        content: '${added.join('\n')}\n',
        kind: 'A',
      ));
      nativeChanges[path] = {'type': 'add', 'content': '${added.join('\n')}\n'};
    } else if (header.startsWith('*** Delete File: ')) {
      final path = resolve(header.substring(17));
      if (!await File(path).exists()) {
        throw StateError('File does not exist: $path');
      }
      changes.add((path: path, destination: null, content: null, kind: 'D'));
      nativeChanges[path] = {'type': 'delete', 'content': await File(path).readAsString().asCancellable(cancellation)};
    } else if (header.startsWith('*** Update File: ')) {
      final path = resolve(header.substring(17));
      String? destination;
      if (lines[i].startsWith('*** Move to: ')) {
        destination = resolve(lines[i++].substring(13));
      }
      final input = ownStream(File(path).openRead(), cancellation);
      final String original;
      try { original = await input.stream.transform(utf8.decoder).join().asCancellable(cancellation); }
      finally { await input.close(); }
      final crlf = original.contains('\r\n');
      final content = original.replaceAll('\r\n', '\n').split('\n');
      if (content.isNotEmpty && content.last.isEmpty) content.removeLast();
      var cursor = 0;
      while (i < lines.length && !lines[i].startsWith('*** ')) {
        if (!lines[i].startsWith('@@')) {
          throw const FormatException('Expected @@ hunk header');
        }
        final marker = lines[i++].substring(2).trim();
        if (marker.isNotEmpty) {
          final found = content.indexOf(marker, cursor);
          if (found < 0) {
            throw StateError('Hunk marker not found in $path: $marker');
          }
          cursor = found + 1;
        }
        final before = <String>[], after = <String>[];
        while (i < lines.length &&
            !lines[i].startsWith('@@') &&
            !lines[i].startsWith('*** ')) {
          final line = lines[i++];
          if (line.isEmpty) {
            throw const FormatException(
              'Hunk lines require a space, +, or - prefix',
            );
          }
          switch (line[0]) {
            case ' ':
              before.add(line.substring(1));
              after.add(line.substring(1));
            case '-':
              before.add(line.substring(1));
            case '+':
              after.add(line.substring(1));
            default:
              throw const FormatException('Invalid hunk line');
          }
        }
        final atEnd = lines[i] == '*** End of File';
        if (atEnd) i++;
        var found = -1;
        for (
          var start = cursor;
          start <= content.length - before.length;
          start++
        ) {
          if (atEnd && start + before.length != content.length) continue;
          if (List.generate(
            before.length,
            (index) => content[start + index] == before[index],
          ).every((same) => same)) {
            found = start;
            break;
          }
        }
        if (found < 0) throw StateError('Patch context not found in $path');
        content.replaceRange(found, found + before.length, after);
        cursor = found + after.length;
      }
      changes.add((
        path: path,
        destination: destination,
        content: content.join(crlf ? '\r\n' : '\n') + (crlf ? '\r\n' : '\n'),
        kind: 'M',
      ));
      nativeChanges[path] = {'type': 'update', 'move_path': destination,
        'unified_diff': unifiedDiff(original, changes.last.content!)};
    } else {
      throw FormatException('Unknown patch header: $header');
    }
  }
  final item = <String, dynamic>{'type': 'FileChange', 'id': callId, 'changes': nativeChanges, 'status': null};
  await onItem?.call('started', item);
  final committed = <Json>[];
  var completed = false, exact = true, mutating = false;
  Future<String?> read(String path) async => await File(path).exists()
    ? await File(path).readAsString().asCancellable(cancellation) : null;
  try {
  for (final change in changes) {
    cancellation.throwIfCancelled();
    final before = await read(change.path);
    final overwritten = change.destination == null ? null : await read(change.destination!);
    if (change.content == null) {
      mutating = true;
      await File(change.path).delete();
    } else {
      final destination = File(change.destination ?? change.path);
      await destination.parent.create(recursive: true);
      cancellation.throwIfCancelled();
      mutating = true;
      await destination.writeAsString(change.content!, flush: true);
      if (change.destination != null && change.destination != change.path) {
        cancellation.throwIfCancelled();
        await File(change.path).delete();
      }
    }
    committed.add({'path': change.path, 'type': change.kind,
      'oldContent': before, 'newContent': change.content, 'movePath': change.destination,
      'overwrittenMoveContent': overwritten});
    mutating = false;
  }
  completed = true;
  return 'Success. Updated the following files:\n${changes.map((change) => '${change.kind} ${change.destination ?? change.path}').join('\n')}';
  } finally {
    if (mutating) exact = false;
    try {
      if (committed.isNotEmpty || !exact) await onPatch?.call({'exact': exact, 'changes': committed});
    } finally { await onItem?.call('completed', {...item, 'status': completed ? 'completed' : 'failed'}); }
  }
}
