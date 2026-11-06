import 'dart:convert';

typedef ChangedFile = ({String path, String? oldPath, String kind, String diff, int additions, int deletions});
typedef DiffLine = ({String kind, String text, int? oldLine, int? newLine});

List<DiffLine> diffLines(String diff) {
  final result = <DiffLine>[];
  var oldLine = 0, newLine = 0, remainingOld = 0, remainingNew = 0;
  for (final line in const LineSplitter().convert(diff)) {
    final hunk = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@').firstMatch(line);
    if (hunk != null) {
      oldLine = int.parse(hunk[1]!); newLine = int.parse(hunk[3]!);
      remainingOld = int.parse(hunk[2] ?? '1'); remainingNew = int.parse(hunk[4] ?? '1');
      result.add((kind: '@', text: line, oldLine: null, newLine: null));
    } else if (line.startsWith(r'\ No newline')) {
      result.add((kind: '\\', text: line, oldLine: null, newLine: null));
    } else if (line.isNotEmpty && (remainingOld > 0 || remainingNew > 0)) {
      final kind = line[0];
      if (!{' ', '+', '-'}.contains(kind)) continue;
      result.add((kind: kind, text: line.substring(1),
        oldLine: kind == '+' ? null : oldLine++, newLine: kind == '-' ? null : newLine++));
      if (kind != '+') remainingOld--;
      if (kind != '-') remainingNew--;
    }
  }
  return result;
}

ChangedFile _changedFile(String path, String? oldPath, String kind, String diff) {
  final lines = diffLines(diff);
  return (path: path, oldPath: oldPath, kind: kind, diff: diff,
    additions: lines.where((line) => line.kind == '+').length,
    deletions: lines.where((line) => line.kind == '-').length);
}

/// App-server FileChange additions/deletions contain file contents; updates
/// contain unified hunks. Keep that distinction out of the widgets.
List<ChangedFile> nativeFileChanges(Object? value) {
  if (value is! List) return const [];
  final result = <ChangedFile>[];
  for (final raw in value.whereType<Map<Object?, Object?>>()) {
    if (raw['path'] is! String) continue;
    final path = raw['path'] as String, kind = raw['kind'];
    final type = kind is Map ? kind['type'] as String? ?? 'update' : 'update';
    final move = kind is Map ? kind['move_path'] as String? : null;
    var diff = raw['diff'] as String? ?? '';
    if (type == 'add' || type == 'delete') {
      final lines = const LineSplitter().convert(diff);
      final added = type == 'add';
      diff = lines.isEmpty ? '' : [
        '@@ -${added ? '0,0' : '1,${lines.length}'} +${added ? '1,${lines.length}' : '0,0'} @@',
        for (final line in lines) '${added ? '+' : '-'}$line',
        if (!diff.endsWith('\n')) r'\ No newline at end of file',
        '',
      ].join('\n');
    }
    result.add(_changedFile(move ?? path, move == null ? null : path, move == null ? type : 'rename', diff));
  }
  return result;
}

List<ChangedFile> turnFileChanges(String diff) {
  final result = <ChangedFile>[];
  String? path, oldPath;
  var kind = 'update', body = <String>[], inHunk = false;
  void flush() {
    if (path != null) result.add(_changedFile(path!, oldPath == path ? null : oldPath, kind, '${body.join('\n')}\n'));
    path = null; oldPath = null; kind = 'update'; body = []; inHunk = false;
  }
  String headerPath(String value) {
    if (value.startsWith('"')) {
      try { value = jsonDecode(value) as String; } on FormatException { /* Display the original path. */ }
    }
    return value.startsWith('a/') || value.startsWith('b/') ? value.substring(2) : value;
  }
  for (final line in const LineSplitter().convert(diff)) {
    if (line.startsWith('diff --git ')) {
      flush();
      final match = RegExp(r'^diff --git "?a/(.*?)"? "?b/(.*?)"?$').firstMatch(line);
      if (match != null) { oldPath = match[1]; path = match[2]; }
    }
    if (line.startsWith('new file mode ')) kind = 'add';
    if (line.startsWith('deleted file mode ')) kind = 'delete';
    if (line.startsWith('@@')) inHunk = true;
    if (!inHunk) {
      if (line.startsWith('--- ') && line != '--- /dev/null') oldPath = headerPath(line.substring(4));
      if (line.startsWith('+++ ') && line != '+++ /dev/null') path = headerPath(line.substring(4));
    }
    body.add(line);
  }
  flush();
  return [for (final file in result)
    if (file.oldPath != null && file.kind == 'update')
      (path: file.path, oldPath: file.oldPath, kind: 'rename', diff: file.diff,
        additions: file.additions, deletions: file.deletions)
    else file];
}
