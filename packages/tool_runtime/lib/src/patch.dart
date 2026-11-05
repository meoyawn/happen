import 'dart:io';
import 'dart:convert';

import 'package:protocol/protocol.dart';

Future<String> applyPatch(String cwd, String patch, {required CancellationToken cancellation,
  String? callId, Future<void> Function(String phase, Json item)? onItem}) async {
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
        'unified_diff': _patchDiff(original, changes.last.content!)};
    } else {
      throw FormatException('Unknown patch header: $header');
    }
  }
  final item = <String, dynamic>{'type': 'FileChange', 'id': callId, 'changes': nativeChanges, 'status': null};
  await onItem?.call('started', item);
  var completed = false;
  try {
  for (final change in changes) {
    cancellation.throwIfCancelled();
    if (change.content == null) {
      await File(change.path).delete();
    } else {
      final destination = File(change.destination ?? change.path);
      await destination.parent.create(recursive: true);
      cancellation.throwIfCancelled();
      await destination.writeAsString(change.content!, flush: true);
      if (change.destination != null && change.destination != change.path) {
        cancellation.throwIfCancelled();
        await File(change.path).delete();
      }
    }
  }
  completed = true;
  return 'Success. Updated the following files:\n${changes.map((change) => '${change.kind} ${change.destination ?? change.path}').join('\n')}';
  } finally { await onItem?.call('completed', {...item, 'status': completed ? 'completed' : 'failed'}); }
}

// FileChange carries a unified preview of the actual prepared before/after
// snapshots, not the caller's patch syntax or guessed headers.
String _patchDiff(String before, String after) {
  List<String> lines(String text) { final values = text.replaceAll('\r\n', '\n').split('\n'); if (values.last.isEmpty) values.removeLast(); return values; }
  final old = lines(before), next = lines(after);
  var prefix = 0, suffix = 0;
  while (prefix < old.length && prefix < next.length && old[prefix] == next[prefix]) { prefix++; }
  while (suffix < old.length - prefix && suffix < next.length - prefix && old[old.length - suffix - 1] == next[next.length - suffix - 1]) { suffix++; }
  final start = (prefix - 3).clamp(0, prefix), oldEnd = (old.length - suffix + 3).clamp(start, old.length), nextEnd = (next.length - suffix + 3).clamp(start, next.length);
  return ['@@ -${start + 1},${oldEnd - start} +${start + 1},${nextEnd - start} @@',
    for (var i = start; i < prefix; i++) ' ${old[i]}',
    for (var i = prefix; i < old.length - suffix; i++) '-${old[i]}',
    for (var i = prefix; i < next.length - suffix; i++) '+${next[i]}',
    for (var i = old.length - suffix; i < oldEnd; i++) ' ${old[i]}', '',
  ].join('\n');
}
