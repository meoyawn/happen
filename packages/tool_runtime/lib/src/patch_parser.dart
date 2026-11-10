// Modified Dart port of Codex apply-patch/{parser,streaming_parser}.rs,
// 0598a96e9361485f. Copyright 2025 OpenAI, Apache-2.0.
// See ../../../openai/tools/CODEX-LICENSE.
part of 'patch.dart';

sealed class _PatchHunk {
  const _PatchHunk(this.path);
  final String path;
}

final class _AddFile extends _PatchHunk {
  const _AddFile(super.path, this.content);
  final String content;
}

final class _DeleteFile extends _PatchHunk {
  const _DeleteFile(super.path);
}

final class _UpdateFile extends _PatchHunk {
  const _UpdateFile(super.path, this.destination, this.chunks);
  final String? destination;
  final List<_PatchChunk> chunks;
}

typedef _PatchChunk = ({String? context, List<String> before, List<String> after,
  List<(int, int)> contextLines, bool atEnd});

({List<_PatchHunk> hunks, String? environment}) _parsePatch(String patch) {
  var lines = patch.trim().split('\n').map((line) => line.endsWith('\r') ? line.substring(0, line.length - 1) : line).toList();
  String? boundaryError(List<String> value) => value.first.trim() != '*** Begin Patch'
    ? "The first line of the patch must be '*** Begin Patch'"
    : value.last.trim() != '*** End Patch' ? "The last line of the patch must be '*** End Patch'" : null;
  var error = boundaryError(lines);
  if (error != null && lines.length >= 4 && ['<<EOF', "<<'EOF'", '<<"EOF"'].contains(lines.first) && lines.last.endsWith('EOF')) {
    lines = lines.sublist(1, lines.length - 1);
    error = boundaryError(lines);
  }
  if (error != null) throw FormatException('invalid patch: $error');
  Never invalid(int line, String message) => throw FormatException('invalid hunk at line $line, $message');
  Never unexpected(int line, String text) => invalid(line, "Unexpected line found in update hunk: '$text'. Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)");
  bool header(String line) => line == '*** End Patch' ||
    ['*** Add File: ', '*** Delete File: ', '*** Update File: '].any(line.startsWith);
  final hunks = <_PatchHunk>[];
  String? environment;
  var i = 1;
  while (i < lines.length - 1) {
    final lineNumber = i + 1, line = lines[i++].trim();
    if (line.startsWith('*** Environment ID:') && hunks.isEmpty) {
      if (environment != null) throw const FormatException('invalid patch: apply_patch environment_id cannot be specified more than once');
      environment = line.substring('*** Environment ID:'.length).trim();
      if (environment.isEmpty) throw const FormatException('invalid patch: apply_patch environment_id cannot be empty');
    } else if (line.startsWith('*** Add File: ')) {
      final content = StringBuffer();
      while (i < lines.length - 1 && lines[i].startsWith('+')) { content.writeln(lines[i++].substring(1)); }
      hunks.add(_AddFile(line.substring(14), content.toString()));
    } else if (line.startsWith('*** Delete File: ')) {
      hunks.add(_DeleteFile(line.substring(17)));
    } else if (line.startsWith('*** Update File: ')) {
      final path = line.substring(17), chunks = <_PatchChunk>[];
      String? destination, context;
      var before = <String>[], after = <String>[], contextLines = <(int, int)>[];
      var hasChunk = false, atEnd = false;
      void finishChunk() {
        if (!hasChunk) return;
        chunks.add((context: context, before: List.unmodifiable(before), after: List.unmodifiable(after),
          contextLines: List.unmodifiable(contextLines), atEnd: atEnd));
      }
      while (i < lines.length) {
        final raw = lines[i], update = raw.trimRight();
        if (header(update) || i == lines.length - 1) {
          if (!hasChunk) invalid(lineNumber, "Update file hunk for path '$path' is empty");
          if (before.isEmpty && after.isEmpty) {
            if (raw.trim() == '*** End Patch') invalid(i + 1, 'Update hunk does not contain any lines');
            unexpected(i + 1, update);
          }
          finishChunk();
          break;
        }
        if (atEnd && update.isEmpty) { i++; continue; }
        final marker = update == '@@' || update.startsWith('@@ ');
        if (atEnd && !marker) invalid(i + 1, "Expected update hunk to start with a @@ context marker, got: '$raw'");
        if (!hasChunk && destination == null && update.startsWith('*** Move to: ')) {
          destination = update.substring(13);
        } else if (marker) {
          if (hasChunk && before.isEmpty && after.isEmpty) unexpected(i + 1, raw);
          finishChunk();
          context = update == '@@' ? null : update.substring(3);
          before = []; after = []; contextLines = [];
          atEnd = false; hasChunk = true;
        } else if (update == '*** End of File') {
          if (hasChunk && before.isEmpty && after.isEmpty) invalid(i + 1, 'Update hunk does not contain any lines');
          if (hasChunk) atEnd = true;
        } else if (raw.isEmpty || raw.startsWith(' ')) {
          hasChunk = true;
          final text = raw.isEmpty ? '' : raw.substring(1);
          contextLines.add((before.length, after.length));
          before.add(text); after.add(text);
        } else if (raw.startsWith('+')) {
          hasChunk = true; after.add(raw.substring(1));
        } else if (raw.startsWith('-')) {
          hasChunk = true; before.add(raw.substring(1));
        } else if (before.isNotEmpty || after.isNotEmpty) {
          invalid(i + 1, "Expected update hunk to start with a @@ context marker, got: '$raw'");
        } else {
          unexpected(i + 1, raw);
        }
        i++;
      }
      hunks.add(_UpdateFile(path, destination, List.unmodifiable(chunks)));
    } else {
      invalid(lineNumber, "'$line' is not a valid hunk header. Valid hunk headers: '*** Add File: {path}', '*** Delete File: {path}', '*** Update File: {path}'");
    }
  }
  return (hunks: List.unmodifiable(hunks), environment: environment);
}
