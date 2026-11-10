import 'dart:typed_data';

// Codex turn_diff_tracker.rs uses a three-line unified diff and bounds the
// expensive comparison to 100 ms, falling back to an exact coarse replacement.
String unifiedDiff(String before, String after, {String? oldPath, String? newPath, int context = 3}) {
  if (before == after) return '';
  List<String> lines(String text) {
    final result = <String>[];
    var start = 0;
    while (start < text.length) {
      final end = text.indexOf('\n', start);
      if (end < 0) { result.add(text.substring(start)); break; }
      result.add(text.substring(start, end + 1));
      start = end + 1;
    }
    return result;
  }
  final old = lines(before), next = lines(after);
  var prefix = 0, suffix = 0;
  while (prefix < old.length && prefix < next.length && old[prefix] == next[prefix]) { prefix++; }
  while (suffix < old.length - prefix && suffix < next.length - prefix &&
      old[old.length - suffix - 1] == next[next.length - suffix - 1]) { suffix++; }
  final edits = <({String kind, String text})>[
    for (var i = 0; i < prefix; i++) (kind: ' ', text: old[i]),
    ..._compareLines(old.sublist(prefix, old.length - suffix), next.sublist(prefix, next.length - suffix)),
    for (var i = old.length - suffix; i < old.length; i++) (kind: ' ', text: old[i]),
  ];
  final changed = [for (var i = 0; i < edits.length; i++) if (edits[i].kind != ' ') i];
  final output = StringBuffer();
  if (oldPath != null && newPath != null) output.write('--- $oldPath\n+++ $newPath\n');
  var oldLine = 1, newLine = 1, cursor = 0, change = 0;
  String range(int line, int count) => count == 1 ? '$line' : '${count == 0 ? line - 1 : line},$count';
  while (change < changed.length) {
    final start = (changed[change] - context).clamp(0, edits.length);
    var end = (changed[change] + context + 1).clamp(0, edits.length);
    change++;
    while (change < changed.length && changed[change] - context <= end) {
      end = (changed[change++] + context + 1).clamp(0, edits.length);
    }
    while (cursor < start) {
      if (edits[cursor].kind != '+') oldLine++;
      if (edits[cursor].kind != '-') newLine++;
      cursor++;
    }
    final oldStart = oldLine, newStart = newLine;
    var oldCount = 0, newCount = 0;
    for (var i = start; i < end; i++) {
      if (edits[i].kind != '+') oldCount++;
      if (edits[i].kind != '-') newCount++;
    }
    output.write('@@ -${range(oldStart, oldCount)} +${range(newStart, newCount)} @@\n');
    while (cursor < end) {
      final edit = edits[cursor++];
      output.write('${edit.kind}${edit.text}');
      if (!edit.text.endsWith('\n')) output.write('\n\\ No newline at end of file\n');
    }
    oldLine += oldCount;
    newLine += newCount;
  }
  return output.toString();
}

List<({String kind, String text})> _compareLines(List<String> old, List<String> next) {
  List<({String kind, String text})> coarse() => [
    for (final line in old) (kind: '-', text: line),
    for (final line in next) (kind: '+', text: line),
  ];
  if (old.isEmpty || next.isEmpty) return coarse();
  final watch = Stopwatch()..start();
  final maximum = old.length + next.length;
  final offset = maximum + 1;
  final frontier = Int32List(maximum * 2 + 3);
  final trace = <Int32List>[];
  var cells = 0;
  for (var distance = 0; distance <= maximum; distance++) {
    if (watch.elapsedMilliseconds >= 100 || cells + distance * 2 + 1 > 1000000) return coarse();
    for (var diagonal = -distance; diagonal <= distance; diagonal += 2) {
      final index = offset + diagonal;
      var x = diagonal == -distance ||
          diagonal != distance && frontier[index - 1] < frontier[index + 1]
        ? frontier[index + 1] : frontier[index - 1] + 1;
      var y = x - diagonal;
      while (x < old.length && y < next.length && old[x] == next[y]) { x++; y++; }
      frontier[index] = x;
      if (x < old.length || y < next.length) continue;
      final result = <({String kind, String text})>[];
      for (var d = distance; d > 0; d--) {
        final previous = trace[d - 1], k = x - y;
        int at(int value) => previous[value + d - 1];
        final previousK = k == -d || k != d && at(k - 1) < at(k + 1) ? k + 1 : k - 1;
        final previousX = at(previousK), previousY = previousX - previousK;
        while (x > previousX && y > previousY) { result.add((kind: ' ', text: old[--x])); y--; }
        if (x == previousX) { result.add((kind: '+', text: next[--y])); }
        else { result.add((kind: '-', text: old[--x])); }
      }
      while (x > 0 && y > 0) { result.add((kind: ' ', text: old[--x])); y--; }
      return result.reversed.toList();
    }
    trace.add(Int32List.fromList(frontier.sublist(offset - distance, offset + distance + 1)));
    cells += distance * 2 + 1;
  }
  return coarse();
}
