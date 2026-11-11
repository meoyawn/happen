import 'package:flutter/foundation.dart';

enum DiffLineKind { context, addition, deletion }

@immutable
class DiffCodeLine {
  const DiffCodeLine(this.text, this.kind, {this.oldLine, this.newLine, this.noNewline = false});
  final String text;
  final DiffLineKind kind;
  final int? oldLine;
  final int? newLine;
  final bool noNewline;
}

@immutable
class DiffHunk {
  const DiffHunk({required this.header, required this.oldStart, required this.newStart, required this.lines});
  final String header;
  final int oldStart;
  final int newStart;
  final List<DiffCodeLine> lines;
}

/// Git owns the comparison. This parser only decodes one file's unified patch;
/// it never re-diffs reconstructed buffers or guesses file names from headers.
@immutable
class DiffPatch {
  const DiffPatch({required this.raw, required this.hunks, this.message});
  final String raw;
  final List<DiffHunk> hunks;
  final String? message;

  factory DiffPatch.parse(String raw, {String? emptyMessage}) {
    final hunks = <DiffHunk>[];
    final headerPattern = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$');
    List<DiffCodeLine>? lines;
    String? header;
    var oldStart = 0, newStart = 0, oldLine = 0, newLine = 0, oldRemaining = 0, newRemaining = 0;
    var binary = false;
    void finish() {
      if (lines == null) return;
      if (oldRemaining != 0 || newRemaining != 0) throw const FormatException('Incomplete Git diff. Refresh changes.');
      hunks.add(DiffHunk(header: header!, oldStart: oldStart, newStart: newStart, lines: List.unmodifiable(lines!)));
      lines = null;
    }
    final records = raw.split('\n');
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      final match = headerPattern.firstMatch(record);
      if (match != null) {
        finish();
        header = record;
        oldLine = oldStart = int.parse(match[1]!);
        newLine = newStart = int.parse(match[3]!);
        oldRemaining = int.parse(match[2] ?? '1');
        newRemaining = int.parse(match[4] ?? '1');
        lines = [];
        continue;
      }
      if (record == r'\ No newline at end of file' && lines?.isNotEmpty == true) {
        final last = lines!.removeLast();
        lines!.add(DiffCodeLine(last.text, last.kind, oldLine: last.oldLine, newLine: last.newLine, noNewline: true));
        continue;
      }
      if (lines != null && (oldRemaining > 0 || newRemaining > 0)) {
        if (record.isEmpty) throw const FormatException('Incomplete Git diff line.');
        switch (record[0]) {
          case ' ':
            lines!.add(DiffCodeLine(record.substring(1), DiffLineKind.context, oldLine: oldLine++, newLine: newLine++));
            oldRemaining--; newRemaining--;
          case '-':
            lines!.add(DiffCodeLine(record.substring(1), DiffLineKind.deletion, oldLine: oldLine++)); oldRemaining--;
          case '+':
            lines!.add(DiffCodeLine(record.substring(1), DiffLineKind.addition, newLine: newLine++)); newRemaining--;
          default: throw const FormatException('Unsupported Git diff line.');
        }
        if (oldRemaining < 0 || newRemaining < 0) throw const FormatException('Invalid Git diff hunk length.');
      } else if (record.startsWith('Binary files ') || record == 'GIT binary patch') {
        binary = true;
      }
    }
    finish();
    return DiffPatch(raw: raw, hunks: List.unmodifiable(hunks),
      message: binary ? 'Binary file not shown' : hunks.isEmpty ? emptyMessage ?? 'No content changes' : null);
  }
}
