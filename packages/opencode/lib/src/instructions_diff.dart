// Port of jsdiff 8.0.4's default diffLines + structuredPatch (context: 3).
// OpenCode chooses between this unified diff and a complete replacement by
// their JavaScript string lengths. See tools/JSDIFF-LICENSE.
String instructionDiff(String before, String after) {
  List<String> tokens(String text) => RegExp(r'[^\n]*\n|[^\n]+$').allMatches(text).map((match) => match[0]!).toList();
  final oldTokens = tokens(before), newTokens = tokens(after);
  final best = <int, _Path>{0: _Path(-1, null)};
  int common(_Path path, int diagonal) {
    var next = path.position - diagonal, count = 0;
    while (path.position + 1 < oldTokens.length && next + 1 < newTokens.length &&
      oldTokens[path.position + 1] == newTokens[next + 1]) {
      path.position++; next++; count++;
    }
    if (count > 0) path.last = _Component(count, 0, path.last);
    return next;
  }
  bool done(_Path path, int next) => path.position + 1 >= oldTokens.length && next + 1 >= newTokens.length;
  var result = best[0]!;
  var complete = done(result, common(result, 0));
  for (var distance = 1; !complete && distance <= oldTokens.length + newTokens.length; distance++) {
    for (var diagonal = -distance; diagonal <= distance; diagonal += 2) {
      final remove = best.remove(diagonal - 1), add = best[diagonal + 1];
      final canAdd = add != null && add.position - diagonal >= 0 && add.position - diagonal < newTokens.length;
      final canRemove = remove != null && remove.position + 1 < oldTokens.length;
      if (!canAdd && !canRemove) { best.remove(diagonal); continue; }
      final adding = !canRemove || canAdd && remove.position < add.position;
      final base = adding ? add! : remove;
      final kind = adding ? 1 : -1, last = base.last;
      final path = _Path(base.position + (adding ? 0 : 1), last?.kind == kind
        ? _Component(last!.count + 1, kind, last.previous) : _Component(1, kind, last));
      if (done(path, common(path, diagonal))) { result = path; complete = true; break; }
      best[diagonal] = path;
    }
  }
  final components = <_Component>[];
  for (var part = result.last; part != null; part = part.previous) { components.add(part); }
  final changes = <({int kind, List<String> lines})>[];
  var oldPosition = 0, newPosition = 0;
  for (final part in components.reversed) {
    changes.add((kind: part.kind, lines: (part.kind == -1
      ? oldTokens.sublist(oldPosition, oldPosition + part.count)
      : newTokens.sublist(newPosition, newPosition + part.count))));
    if (part.kind != 1) oldPosition += part.count;
    if (part.kind != -1) newPosition += part.count;
  }
  changes.add((kind: 0, lines: []));
  var oldStart = 0, newStart = 0, oldLine = 1, newLine = 1;
  var range = <String>[];
  final output = <String>[];
  for (var index = 0; index < changes.length; index++) {
    final change = changes[index], lines = change.lines;
    if (change.kind != 0) {
      if (oldStart == 0) {
        oldStart = oldLine; newStart = newLine;
        if (index > 0) {
          final previous = changes[index - 1].lines;
          range = previous.skip((previous.length - 3).clamp(0, previous.length)).map((line) => ' $line').toList();
          oldStart -= range.length; newStart -= range.length;
        }
      }
      range.addAll(lines.map((line) => '${change.kind == 1 ? '+' : '-'}$line'));
      if (change.kind == 1) { newLine += lines.length; } else { oldLine += lines.length; }
    } else {
      if (oldStart != 0) {
        if (lines.length <= 6 && index < changes.length - 2) {
          range.addAll(lines.map((line) => ' $line'));
        } else {
          final count = lines.length.clamp(0, 3);
          range.addAll(lines.take(count).map((line) => ' $line'));
          final oldCount = oldLine - oldStart + count, newCount = newLine - newStart + count;
          output.add('@@ -${oldStart - (oldCount == 0 ? 1 : 0)},$oldCount +${newStart - (newCount == 0 ? 1 : 0)},$newCount @@');
          for (final line in range) {
            output.add(line.endsWith('\n') ? line.substring(0, line.length - 1) : line);
            if (!line.endsWith('\n')) output.add(r'\ No newline at end of file');
          }
          oldStart = 0; newStart = 0; range = [];
        }
      }
      oldLine += lines.length; newLine += lines.length;
    }
  }
  return output.join('\n').trimRight();
}

class _Path {
  _Path(this.position, this.last);
  int position;
  _Component? last;
}

class _Component {
  const _Component(this.count, this.kind, this.previous);
  final int count, kind;
  final _Component? previous;
}
