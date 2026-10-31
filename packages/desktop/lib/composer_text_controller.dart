import 'package:flutter/material.dart';

import 'inline_reference.dart';

/// A file or skill occupies one UTF-16 position, like Harness's mention atoms.
@immutable
class ComposerFileReference {
  const ComposerFileReference(this.offset, this.path, {this.skillName});
  final int offset;
  final String path;
  final String? skillName;
  bool get folder => path.endsWith('/');
  String get label => skillName ?? path.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).last;
  String get markdown {
    final title = (skillName == null ? label : '\$$label').replaceAll('\\', '\\\\').replaceAll('[', r'\[').replaceAll('](', r']\(').replaceAll(']', r'\]');
    final destination = path.replaceAll('\\', '\\\\').replaceAll(')', r'\)');
    return '[$title]($destination)';
  }
  ComposerFileReference shifted(int delta) => ComposerFileReference(offset + delta, path, skillName: skillName);
}

/// Keeps reference identity out of editable text and serializes it at the edge.
class ComposerTextController extends TextEditingController {
  ComposerTextController({super.text, List<ComposerFileReference> files = const []}) {
    _files.addAll(files.where(_valid));
    _remember();
  }
  ComposerTextController.fromValue(super.value) : super.fromValue();

  static const marker = '\uFFFC';
  final _files = <ComposerFileReference>[];
  // Flutter's desktop UndoHistory retains these exact editing values. Weak
  // snapshots keep metadata alive for the same lifetime as its undo entries.
  final _snapshots = Expando<List<ComposerFileReference>>();
  List<ComposerFileReference> get files => List.unmodifiable(_files.where(_valid));
  bool _valid(ComposerFileReference file) => file.offset >= 0 && file.offset < text.length && text[file.offset] == marker;
  void _remember() => _snapshots[super.value] = files;

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
      output.write(file.markdown);
      offset = file.offset + 1;
    }
    output.write(text.substring(offset, end));
    return output.toString();
  }

  String serializePrompt() => serializeRange(0, text.length);

  void insertFile(TextRange range, String path, {String? skillName}) {
    final followingSpace = range.end < text.length && RegExp(r'\s').hasMatch(text[range.end]);
    final replacement = '$marker${followingSpace ? '' : ' '}';
    final result = text.replaceRange(range.start, range.end, replacement);
    _replaceFiles(range.start, range.end, replacement.length);
    _files.add(ComposerFileReference(range.start, path, skillName: skillName));
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
    if (previous.text != next.text) {
      var start = 0;
      while (start < previous.text.length && start < next.text.length && previous.text[start] == next.text[start]) {
        start++;
      }
      var oldEnd = previous.text.length, newEnd = next.text.length;
      while (oldEnd > start && newEnd > start && previous.text[oldEnd - 1] == next.text[newEnd - 1]) {
        oldEnd--;
        newEnd--;
      }
      // Identical adjacent markers still have different paths. Prefer the
      // actual selection over a common-prefix diff for replacement/deletion.
      final selection = previous.selection;
      if (selection.isValid && next.selection.isValid && next.selection.isCollapsed) {
        final delta = next.text.length - previous.text.length;
        final from = selection.isCollapsed && delta < 0 ? next.selection.start : selection.start;
        final end = selection.isCollapsed && delta < 0 ? from - delta : selection.end;
        final to = end + delta;
        if (from >= 0 && end <= previous.text.length && to >= from && to <= next.text.length &&
            previous.text.substring(0, from) == next.text.substring(0, from) &&
            previous.text.substring(end) == next.text.substring(to)) {
          start = from;
          oldEnd = end;
          newEnd = to;
        }
      }
      _replaceFiles(start, oldEnd, newEnd - start);
    }
    super.value = next;
    _remember();
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

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (_files.isEmpty) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    final spans = <InlineSpan>[];
    final composing = value.composing;
    void plain(int start, int end) {
      if (start >= end) return;
      if (!withComposing || !composing.isValid || composing.isCollapsed || composing.end <= start || composing.start >= end) {
        spans.add(TextSpan(text: text.substring(start, end)));
        return;
      }
      final from = composing.start.clamp(start, end), to = composing.end.clamp(start, end);
      if (start < from) spans.add(TextSpan(text: text.substring(start, from)));
      spans.add(TextSpan(text: text.substring(from, to), style: const TextStyle(decoration: TextDecoration.underline)));
      if (to < end) spans.add(TextSpan(text: text.substring(to, end)));
    }
    var offset = 0;
    for (final file in _files.where(_valid)) {
      plain(offset, file.offset);
      spans.add(WidgetSpan(alignment: PlaceholderAlignment.middle,
        child: Semantics(label: file.label, excludeSemantics: true,
          child: Tooltip(message: file.path, child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (file.skillName != null) const SkillIcon()
            else Icon(file.folder ? Icons.folder_outlined : Icons.insert_drive_file_outlined, size: 16, color: inlineReferenceAccent),
            const SizedBox(width: 3),
            Flexible(child: Text(file.label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: (style ?? const TextStyle()).copyWith(fontWeight: FontWeight.w500, color: inlineReferenceAccent))),
          ])),
        )));
      offset = file.offset + 1;
    }
    plain(offset, text.length);
    return TextSpan(style: style, children: spans);
  }
}
