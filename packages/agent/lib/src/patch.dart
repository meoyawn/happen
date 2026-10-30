import 'dart:io';

Future<String> applyPatch(String cwd, String patch) async {
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
  var i = 1;
  String resolve(String path) => File(path).isAbsolute ? path : '$cwd/$path';
  while (i < lines.length - 1) {
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
    } else if (header.startsWith('*** Delete File: ')) {
      final path = resolve(header.substring(17));
      if (!await File(path).exists()) {
        throw StateError('File does not exist: $path');
      }
      changes.add((path: path, destination: null, content: null, kind: 'D'));
    } else if (header.startsWith('*** Update File: ')) {
      final path = resolve(header.substring(17));
      String? destination;
      if (lines[i].startsWith('*** Move to: ')) {
        destination = resolve(lines[i++].substring(13));
      }
      final original = await File(path).readAsString();
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
    } else {
      throw FormatException('Unknown patch header: $header');
    }
  }
  for (final change in changes) {
    if (change.content == null) {
      await File(change.path).delete();
    } else {
      final destination = File(change.destination ?? change.path);
      await destination.parent.create(recursive: true);
      await destination.writeAsString(change.content!, flush: true);
      if (change.destination != null && change.destination != change.path) {
        await File(change.path).delete();
      }
    }
  }
  return 'Success. Updated the following files:\n${changes.map((change) => '${change.kind} ${change.destination ?? change.path}').join('\n')}';
}
