import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'appearance.dart';
import 'conversation_markdown.dart' show ConversationCopyButton;
import 'file_change.dart';
import 'file_icon.dart';
import 'file_reference.dart';

const diffAdded = Color(0xff16803c), diffRemoved = Color(0xffc23838);

class DiffStat extends StatelessWidget {
  const DiffStat({super.key, required this.additions, required this.deletions});
  final int additions, deletions;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    if (additions > 0) Text('+$additions', style: const TextStyle(fontFamily: 'IBM Plex Mono',
      fontSize: 11, color: diffAdded, fontFeatures: [FontFeature.tabularFigures()])),
    if (additions > 0 && deletions > 0) const SizedBox(width: 7),
    if (deletions > 0) Text('−$deletions', style: const TextStyle(fontFamily: 'IBM Plex Mono',
      fontSize: 11, color: diffRemoved, fontFeatures: [FontFeature.tabularFigures()])),
  ]);
}

class DiffViewer extends StatefulWidget {
  const DiffViewer({super.key, required this.files, this.selectedPath, this.revealRevision = 0, this.directory = '', this.onSelect});
  final List<ChangedFile> files;
  final String? selectedPath;
  final int revealRevision;
  final String directory;
  final ValueChanged<String>? onSelect;
  @override
  State<DiffViewer> createState() => _DiffViewerState();
}

class _DiffViewerState extends State<DiffViewer> {
  final _vertical = ScrollController(), _horizontal = ScrollController();
  String? _path;
  bool _split = false;
  ChangedFile? _file;
  List<DiffLine> _lines = [];
  List<({DiffLine? left, DiffLine? right})> _pairs = [];

  @override
  void initState() { super.initState(); _select(widget.selectedPath); }
  @override
  void didUpdateWidget(DiffViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revealRevision != widget.revealRevision || oldWidget.selectedPath != widget.selectedPath) {
      _select(widget.selectedPath);
    } else if (oldWidget.files != widget.files) { _select(_path, reset: false); }
  }
  void _select(String? path, {bool reset = true}) {
    _file = widget.files.where((file) => file.path == path).firstOrNull ?? widget.files.firstOrNull;
    _path = _file?.path;
    _lines = diffLines(_file?.diff ?? '');
    _pairs = _splitLines(_lines);
    if (reset) {
      if (_vertical.hasClients) _vertical.jumpTo(0);
      if (_horizontal.hasClients) _horizontal.jumpTo(0);
    }
  }
  void _choose(String path) {
    setState(() => _select(path));
    widget.onSelect?.call(path);
  }
  @override
  void dispose() { _vertical.dispose(); _horizontal.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final file = _file, files = widget.files;
    if (file == null) return const Center(child: Text('No file changes', style: TextStyle(color: conversationSecondary)));
    final index = files.indexOf(file);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(12, 6, 8, 6), child: Row(children: [
        FileIcon(file.path, size: 16), const SizedBox(width: 8),
        Expanded(child: DropdownButtonHideUnderline(child: DropdownButton<String>(
          value: file.path, isExpanded: true, isDense: true,
          style: const TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 11, color: conversationForeground),
          items: [for (final item in files) DropdownMenuItem(value: item.path,
            child: Text(item.path, maxLines: 1, overflow: TextOverflow.ellipsis))],
          onChanged: (path) { if (path != null) _choose(path); }))),
        const SizedBox(width: 12), DiffStat(additions: file.additions, deletions: file.deletions),
      ])),
      Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 6), child: Row(children: [
        _button('Previous file', Icons.chevron_left_rounded,
          index > 0 ? () => _choose(files[index - 1].path) : null),
        Text('${index + 1} / ${files.length}', style: const TextStyle(fontSize: 11, color: conversationSecondary)),
        _button('Next file', Icons.chevron_right_rounded,
          index + 1 < files.length ? () => _choose(files[index + 1].path) : null),
        const Spacer(),
        _button(_split ? 'Unified diff' : 'Split diff', _split ? Icons.view_agenda_outlined : Icons.vertical_split_outlined,
          () => setState(() => _split = !_split)),
        ConversationCopyButton(text: file.diff, label: 'Copy diff', compact: true),
        if (file.kind != 'delete') _button('Open file', Icons.open_in_new_rounded,
          () {
            final location = conversationFileLocation(file.path, widget.directory);
            if (location != null) ConversationFileScope.open(context, location);
          }),
      ])),
      if (file.oldPath != null) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Text('${file.oldPath} → ${file.path}', style: const TextStyle(fontSize: 11, color: conversationSecondary))),
      const Divider(height: 1),
      Expanded(child: _lines.isEmpty
        ? const Center(child: Text('No line changes', style: TextStyle(fontSize: 12, color: conversationSecondary)))
        : LayoutBuilder(builder: (context, bounds) {
          final longest = _lines.fold<int>(0, (size, line) => math.max(size, line.text.length));
          final columnWidth = math.max(_split ? bounds.maxWidth / 2 : bounds.maxWidth, longest * 7.2 + (_split ? 76 : 128));
          return Scrollbar(controller: _horizontal, notificationPredicate: (notification) => notification.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(controller: _horizontal, scrollDirection: Axis.horizontal,
              child: SizedBox(width: _split ? columnWidth * 2 : columnWidth,
                child: Scrollbar(controller: _vertical, child: ListView.builder(controller: _vertical,
                  itemExtent: 22, itemCount: _split ? _pairs.length : _lines.length,
                  itemBuilder: (context, index) => _split
                    ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Expanded(child: _line(_pairs[index].left, oldSide: true)),
                        const VerticalDivider(width: 1),
                        Expanded(child: _line(_pairs[index].right, oldSide: false)),
                      ])
                    : _line(_lines[index]))))));
        })),
    ]);
  }

  Widget _button(String label, IconData icon, VoidCallback? action) => SizedBox.square(dimension: 28,
    child: IconButton(tooltip: label, onPressed: action, padding: EdgeInsets.zero,
      style: IconButton.styleFrom(minimumSize: const Size.square(28), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
      icon: Icon(icon, size: 15, color: action == null ? conversationOutline : conversationSecondary)));

  Widget _line(DiffLine? line, {bool? oldSide}) {
    final added = line?.kind == '+', removed = line?.kind == '-', hunk = line?.kind == '@';
    final color = added ? const Color(0xffeaf7ee) : removed ? const Color(0xfffcecec)
      : hunk ? const Color(0xffedf2fa) : line == null ? const Color(0xfff8f8f9) : Colors.white;
    const numberStyle = TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 10, color: conversationSecondary,
      fontFeatures: [FontFeature.tabularFigures()]);
    return ColoredBox(color: color, child: Row(children: [
      SizedBox(width: 48, child: Text('${(oldSide == false ? line?.newLine : line?.oldLine) ?? ''}',
        textAlign: TextAlign.right, style: numberStyle)),
      if (oldSide == null) SizedBox(width: 48, child: Text('${line?.newLine ?? ''}', textAlign: TextAlign.right, style: numberStyle)),
      SizedBox(width: 24, child: Text(added ? '+' : removed ? '−' : '', textAlign: TextAlign.center,
        style: TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 12, color: added ? diffAdded : diffRemoved))),
      Expanded(child: SelectableText(line?.text ?? '', maxLines: 1,
        style: TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 12, height: 1.6,
          color: hunk || line?.kind == '\\' ? conversationSecondary : conversationForeground))),
    ]));
  }
}

List<({DiffLine? left, DiffLine? right})> _splitLines(List<DiffLine> lines) {
  final result = <({DiffLine? left, DiffLine? right})>[];
  for (var i = 0; i < lines.length;) {
    if (lines[i].kind != '-' && lines[i].kind != '+') {
      result.add((left: lines[i], right: lines[i])); i++; continue;
    }
    final left = <DiffLine>[], right = <DiffLine>[];
    while (i < lines.length && {'-', '+'}.contains(lines[i].kind)) {
      (lines[i].kind == '-' ? left : right).add(lines[i++]);
    }
    for (var j = 0; j < math.max(left.length, right.length); j++) {
      result.add((left: j < left.length ? left[j] : null, right: j < right.length ? right[j] : null));
    }
  }
  return result;
}
