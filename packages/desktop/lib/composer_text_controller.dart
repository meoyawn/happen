import 'package:flutter/material.dart';

/// A reference is stored as one position and expanded by the virtual editor.
@immutable
class ComposerFileReference {
  const ComposerFileReference(this.offset, this.path, {this.skillName, this.title, this.prompt});
  final int offset;
  final String path;
  final String? skillName;
  final String? title, prompt;
  bool get folder => path.endsWith('/');
  String get label => (title ?? skillName ?? path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).lastOrNull ?? path)
    .replaceAll(RegExp(r'[\r\n\t]'), ' ');
  String get markdown {
    final title = (skillName == null ? label : '\$$label').replaceAll('\\', '\\\\').replaceAll('[', r'\[').replaceAll('](', r']\(').replaceAll(']', r'\]');
    final destination = path.replaceAll('\\', '\\\\').replaceAll(')', r'\)');
    return '[$title]($destination)';
  }
  ComposerFileReference shifted(int delta) => ComposerFileReference(offset + delta, path,
    skillName: skillName, title: title, prompt: prompt);
}

/// Keeps reference identity out of editable text and serializes it at the edge.
class ComposerTextController extends TextEditingController {
  ComposerTextController({super.text, List<ComposerFileReference> files = const []}) {
    _files.addAll(files.where(_valid));
    _remember();
  }
  static const marker = '\uFFFC';
  final _files = <ComposerFileReference>[];
  // Programmatic restoration retains reference metadata with its editing value.
  // The virtual editor owns native undo history and its own weak snapshots.
  final _snapshots = Expando<List<ComposerFileReference>>();
  List<ComposerFileReference> get files => List.unmodifiable(_files.where(_valid));
  bool _valid(ComposerFileReference file) => file.offset >= 0 && file.offset < text.length && text[file.offset] == marker;
  void _remember() => _snapshots[super.value] = files;

  /// The editor already knows its reference ranges; avoid rediscovering an edit.
  void applyEditorValue(TextEditingValue next, List<ComposerFileReference> references) {
    _files..clear()..addAll(references);
    super.value = next;
    if (_files.isNotEmpty) _remember();
  }

  void restoreFiles(int start, List<ComposerFileReference> references) {
    for (final reference in references) {
      final restored = reference.shifted(start);
      if (_valid(restored) && !_files.any((file) => file.offset == restored.offset)) _files.add(restored);
    }
    _files.sort((a, b) => a.offset.compareTo(b.offset));
    _remember();
    notifyListeners();
  }

  String serializeRange(int start, int end) {
    final output = StringBuffer();
    var offset = start;
    for (final file in _files.where(_valid)) {
      if (file.offset < start || file.offset >= end) continue;
      output.write(text.substring(offset, file.offset));
      output.write(file.prompt ?? file.markdown);
      offset = file.offset + 1;
    }
    output.write(text.substring(offset, end));
    return output.toString();
  }

  String serializePrompt() => serializeRange(0, text.length);

  void insertFile(TextRange range, String path, {String? skillName, String? title, String? prompt}) {
    final followingSpace = range.end < text.length && RegExp(r'\s').hasMatch(text[range.end]);
    final replacement = '$marker${followingSpace ? '' : ' '}';
    final result = text.replaceRange(range.start, range.end, replacement);
    _replaceFiles(range.start, range.end, replacement.length);
    _files.add(ComposerFileReference(range.start, path, skillName: skillName, title: title, prompt: prompt));
    _files.sort((a, b) => a.offset.compareTo(b.offset));
    super.value = TextEditingValue(text: result,
      selection: TextSelection.collapsed(offset: range.start + 2));
    _remember();
  }

  @override
  set text(String text) {
    _files.clear();
    super.text = text;
  }

  @override
  set value(TextEditingValue next) {
    final restored = _snapshots[next];
    if (restored != null) {
      _files..clear()..addAll(restored);
      super.value = next;
      _remember();
      return;
    }
    final previous = super.value;
    if (_files.isNotEmpty && previous.text != next.text) {
      final edit = composerReplacement(previous, next);
      _replaceFiles(edit.start, edit.end, edit.inserted);
    }
    super.value = next;
    if (_files.isNotEmpty) _remember();
  }

  void _replaceFiles(int start, int end, int insertedLength) {
    final delta = insertedLength - (end - start);
    final retained = <ComposerFileReference>[
      for (final file in _files)
        if (file.offset < start) file
        else if (file.offset >= end) file.shifted(delta),
    ];
    _files..clear()..addAll(retained);
  }

}

/// Prefer the actual edit selection, including adjacent identical references.
/// The fallback is only needed for programmatic replacements and composition.
({int start, int end, int inserted}) composerReplacement(TextEditingValue before, TextEditingValue after) {
  final delta = after.text.length - before.text.length;
  if (before.selection.isValid && after.selection.isValid && after.selection.isCollapsed) {
    final from = before.selection.isCollapsed && delta < 0 ? after.selection.start : before.selection.start;
    final end = before.selection.isCollapsed && delta < 0 ? from - delta : before.selection.end;
    final to = end + delta;
    if (from >= 0 && end <= before.text.length && to >= from && to <= after.text.length &&
        before.text.substring(0, from) == after.text.substring(0, from) &&
        before.text.substring(end) == after.text.substring(to)) {
      return (start: from, end: end, inserted: to - from);
    }
  }
  var start = 0, end = before.text.length, to = after.text.length;
  while (start < end && start < to && before.text.codeUnitAt(start) == after.text.codeUnitAt(start)) { start++; }
  while (end > start && to > start && before.text.codeUnitAt(end - 1) == after.text.codeUnitAt(to - 1)) { end--; to--; }
  return (start: start, end: end, inserted: to - start);
}
