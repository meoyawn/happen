// Modified Dart port of Codex apply-patch/{file_update,text_file,seek_sequence}.rs,
// 0598a96e9361485f. Copyright 2025 OpenAI, Apache-2.0.
// See ../../../openai/tools/CODEX-LICENSE.
part of 'patch.dart';

String _normalizePatchLine(String line) => line.trim()
  .replaceAll(RegExp('[\u2010-\u2015\u2212]'), '-')
  .replaceAll(RegExp('[\u2018-\u201b]'), "'")
  .replaceAll(RegExp('[\u201c-\u201f]'), '"')
  .replaceAll(RegExp('[\u00a0\u2002-\u200a\u202f\u205f\u3000]'), ' ');

int _seekPatchSequence(List<String> lines, List<String> pattern, int start, bool eof) {
  if (pattern.isEmpty) return start;
  if (pattern.length > lines.length) return -1;
  final last = lines.length - pattern.length;
  final first = eof && last > start ? last : start;
  for (final normalize in <String Function(String)>[(line) => line, (line) => line.trimRight(), (line) => line.trim(), _normalizePatchLine]) {
    for (var i = first; i <= last; i++) {
      var matches = true;
      for (var j = 0; j < pattern.length; j++) {
        if (normalize(lines[i + j]) != normalize(pattern[j])) { matches = false; break; }
      }
      if (matches) return i;
    }
  }
  return -1;
}

String _patchContents(String original, String path, List<_PatchChunk> chunks) {
  final source = <({String text, String? ending})>[];
  String? preferred;
  var offset = 0;
  for (final match in RegExp(r'\r\n|\r|\n').allMatches(original)) {
    preferred ??= match[0];
    source.add((text: original.substring(offset, match.start), ending: match[0]));
    offset = match.end;
  }
  if (offset < original.length) source.add((text: original.substring(offset), ending: null));
  final ending = preferred ?? '\n', lines = source.map((line) => line.text).toList();
  final replacements = <({int start, int oldLength, List<String> lines})>[];
  var cursor = 0;
  for (final chunk in chunks) {
    if (chunk.context case final context?) {
      final found = _seekPatchSequence(lines, [context], cursor, false);
      if (found < 0) throw StateError("Failed to find context '$context' in $path");
      cursor = found + 1;
    }
    if (chunk.before.isEmpty) {
      replacements.add((start: lines.length, oldLength: 0, lines: chunk.after));
      continue;
    }
    var before = chunk.before, after = chunk.after;
    var found = _seekPatchSequence(lines, before, cursor, chunk.atEnd);
    if (found < 0 && before.last.isEmpty) {
      before = before.sublist(0, before.length - 1);
      if (after.isNotEmpty && after.last.isEmpty) after = after.sublist(0, after.length - 1);
      found = _seekPatchSequence(lines, before, cursor, chunk.atEnd);
    }
    if (found < 0) throw StateError('Failed to find expected lines in $path:\n${chunk.before.join('\n')}');
    var oldStart = 0, newStart = 0;
    for (final (oldContext, newContext) in chunk.contextLines) {
      if (oldContext >= before.length || newContext >= after.length) break;
      if (oldStart != oldContext || newStart != newContext) {
        replacements.add((start: found + oldStart, oldLength: oldContext - oldStart, lines: after.sublist(newStart, newContext)));
      }
      oldStart = oldContext + 1; newStart = newContext + 1;
    }
    if (oldStart != before.length || newStart != after.length) {
      replacements.add((start: found + oldStart, oldLength: before.length - oldStart, lines: after.sublist(newStart)));
    }
    cursor = found + before.length;
  }
  // Rust's sort_by_key is stable. Keep equal-position insertions in patch order.
  final ordered = replacements.indexed.toList()..sort((a, b) {
    final order = a.$2.start.compareTo(b.$2.start);
    return order == 0 ? a.$1.compareTo(b.$1) : order;
  });
  final output = StringBuffer();
  var position = 0;
  void retain(int end) {
    while (position < end) {
      final line = source[position++];
      output.write('${line.text}${line.ending ?? ending}');
    }
  }
  for (final (_, replacement) in ordered) {
    retain(replacement.start);
    position = replacement.start + replacement.oldLength;
    for (final line in replacement.lines) { output.write('$line$ending'); }
  }
  retain(source.length);
  return output.toString();
}
