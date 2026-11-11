import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'conversation_markdown.dart' show ConversationCopyButton;
import 'diff_patch.dart';
import 'diff_syntax.dart';
import 'file_change.dart';
import 'file_icon.dart';
import 'file_reference.dart';

const diffAdded = Color(0xff16803c), diffRemoved = desktopError;
const _added = Color(0xff00a240), _deleted = Color(0xffba2623);
const _code = TextStyle(inherit: false, color: desktopForeground, fontFamily: desktopMonoFamily, fontSize: 12, height: 1.8);
const _palette = (surface: desktopSurface, surfaceUnder: desktopSidebar, secondaryBackground: desktopMuted,
  foregroundSecondary: desktopSecondary, foregroundTertiary: desktopTertiary, border: desktopBorder, borderLight: desktopBorderSubtle);

typedef DiffPatchLoader = Future<({ChangedFile file, bool truncated})> Function(
  String path, bool hideWhitespace, CancellationToken cancellation);

class DiffStat extends StatelessWidget {
  const DiffStat({super.key, required this.additions, required this.deletions});
  final int additions, deletions;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    if (additions > 0) Text('+${MaterialLocalizations.of(context).formatDecimal(additions)}', style: const TextStyle(fontFamily: desktopMonoFamily,
      fontSize: 11, color: diffAdded, fontFeatures: [FontFeature.tabularFigures()])),
    if (additions > 0 && deletions > 0) const SizedBox(width: 7),
    if (deletions > 0) Text('−${MaterialLocalizations.of(context).formatDecimal(deletions)}', style: const TextStyle(fontFamily: desktopMonoFamily,
      fontSize: 11, color: diffRemoved, fontFeatures: [FontFeature.tabularFigures()])),
  ]);
}

/// One retained review for either immutable conversation patches or lazily read
/// checkout patches. File bytes and cancellation belong to this view's target.
class DiffViewer extends StatefulWidget {
  const DiffViewer({super.key, required this.files, this.selectedPath, this.revealRevision = 0,
    this.directory = '', this.onSelect, this.loadPatch, this.revision = 0, this.active = true,
    this.loading = false, this.error, this.onRefresh, this.comparison, this.emptyLabel = 'No file changes'});
  final List<ChangedFile> files;
  final String? selectedPath;
  final int revealRevision;
  final String directory;
  final ValueChanged<String>? onSelect;
  final DiffPatchLoader? loadPatch;
  final int revision;
  final bool active, loading;
  final String? error;
  final Future<void> Function()? onRefresh;
  final Widget? comparison;
  final String emptyLabel;
  @override
  State<DiffViewer> createState() => _DiffViewerState();
}

class _PatchContent {
  const _PatchContent(this.patch, this.syntax);
  final DiffPatch patch;
  final DiffSyntax syntax;
}

sealed class _PatchState {
  const _PatchState(this.generation, this.content);
  final int generation;
  final _PatchContent? content;
  DiffPatch? get patch => content?.patch;
  DiffSyntax? get syntax => content?.syntax;
  String? get error => null;
}
final class _PatchPending extends _PatchState { const _PatchPending(super.generation, super.content); }
final class _PatchReady extends _PatchState { const _PatchReady(super.generation, super.content); }
final class _PatchFailed extends _PatchState {
  const _PatchFailed(super.generation, super.content, this.message);
  final String message;
  @override
  String get error => message;
}

_PatchState _patchTransition(_PatchState? current, _PatchState next) => switch ((current, next)) {
  (null, _PatchPending()) => next,
  (_PatchPending() || _PatchReady() || _PatchFailed(), _PatchPending()) => next,
  (_PatchPending(), _PatchReady() || _PatchFailed()) => next,
  _ => throw StateError('Invalid diff read transition'),
};

enum _RowKind { file, hunk, line, message }
class _DiffRow {
  const _DiffRow(this.id, this.file, this.kind, {this.label = '', this.left, this.right, this.split = false, this.counterpart});
  final String id;
  final ChangedFile file;
  final _RowKind kind;
  final String label;
  final DiffCodeLine? left, right, counterpart;
  final bool split;
}

class _DiffViewerState extends State<DiffViewer> {
  final _vertical = ScrollController(), _horizontal = ScrollController();
  String? _path;
  late final _filter = TextEditingController()..addListener(_filtered);
  late final _selected = ValueNotifier<String?>(widget.selectedPath ?? _path);
  late final _reads = <String, _PatchState>{};
  late final _queue = <ChangedFile>[];
  late final _tokens = <String, CancellationToken>{};
  late final _collapsed = <String>{};
  List<_DiffRow> _rows = [];
  _DiffLayout? _layout;
  (String, double)? _anchor;
  String? _reveal;
  String _mode = 'auto';
  bool _wrap = false, _wordDiffs = true, _hideWhitespace = false, _allCollapsed = false;
  int _generation = 0, _running = 0, _retainedBytes = 0;
  double _longest = 0, _numberColumnWidth = 40;
  DiffHighlighter? _highlighter;
  DiffHighlighter get _syntax => _highlighter ??= DiffHighlighter();

  @override
  void initState() {
    super.initState();
    _vertical.addListener(_scrolled);
    _reveal = widget.selectedPath;
    _rebuildRows();
  }

  @override
  void didUpdateWidget(DiffViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.directory != widget.directory || oldWidget.revision != widget.revision ||
        oldWidget.files != widget.files || oldWidget.active != widget.active) {
      _rememberAnchor();
      _invalidate(retain: oldWidget.directory == widget.directory);
    }
    if (oldWidget.selectedPath != widget.selectedPath || oldWidget.revealRevision != widget.revealRevision) {
      final file = widget.files.where((file) => file.path == widget.selectedPath).firstOrNull;
      if (file != null) _jump(file, notify: false);
    }
  }

  @override
  void reassemble() {
    super.reassemble();
    // Adopt the multi-file projection in an already-mounted single-file viewer.
    _vertical.removeListener(_scrolled); _vertical.addListener(_scrolled);
    _rememberAnchor();
    final highlighter = _highlighter; _highlighter = null;
    if (highlighter != null) unawaited(highlighter.dispose());
    _invalidate();
  }

  void _filtered() { if (mounted) setState(() {}); }

  void _invalidate({bool retain = true}) {
    _generation++;
    _queue.clear();
    for (final token in _tokens.values) { token.cancel(); }
    _tokens.clear();
    if (!widget.active || !retain) {
      final highlighter = _highlighter; _highlighter = null;
      if (highlighter != null) unawaited(highlighter.dispose());
    }
    final paths = widget.files.map((file) => file.path).toSet();
    if (!retain) _reads.clear();
    _reads.removeWhere((path, _) => !paths.contains(path));
    _retainedBytes = _reads.values.fold(0, (sum, read) => sum + (read.patch?.raw.length ?? 0) * 2);
    _longest = 0;
    for (final read in _reads.values) { if (read.patch case final patch?) _measurePatch(patch); }
    _rebuildRows();
  }

  void _rememberAnchor() {
    final layout = _layout;
    if (layout == null || _rows.isEmpty || !_vertical.hasClients) return;
    final index = layout.indexAt(_vertical.offset);
    _anchor = (_rows[index].id, _vertical.offset - layout.offset(index));
  }

  void _rebuildRows() {
    final rows = <_DiffRow>[];
    final files = [...widget.files]..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      rows.add(_DiffRow('file:${file.path}', file, _RowKind.file));
      if (_isCollapsed(file.path)) continue;
      final read = _reads[file.path], patch = read?.patch;
      if (patch == null || patch.hunks.isEmpty) {
        rows.add(_DiffRow('message:${file.path}', file, _RowKind.message,
          label: read?.error ?? patch?.message ?? 'Loading diff…'));
        continue;
      }
      if (read?.error case final error?) {
        rows.add(_DiffRow('error:${file.path}', file, _RowKind.message,
          label: '$error Showing the last successful diff.'));
      }
      final split = _mode == 'split' || _mode == 'auto' && file.additions > 0 && file.deletions > 0;
      final hunks = _hideWhitespace && widget.loadPatch == null ? _withoutWhitespace(patch.hunks) : patch.hunks;
      if (hunks.isEmpty) rows.add(_DiffRow('message:${file.path}', file, _RowKind.message, label: 'No changes beyond white space'));
      for (var h = 0; h < hunks.length; h++) {
        final hunk = hunks[h];
        rows.add(_DiffRow('hunk:${file.path}:$h', file, _RowKind.hunk, label: hunk.header));
        final lines = hunk.lines;
        void add(DiffCodeLine? left, DiffCodeLine? right, {DiffCodeLine? counterpart}) {
          final identity = right ?? left!;
          rows.add(_DiffRow('line:${file.path}:$h:${identity.kind.name}:${identity.oldLine}:${identity.newLine}', file, _RowKind.line,
            left: left, right: right, split: split, counterpart: counterpart));
        }
        for (var i = 0; i < lines.length;) {
          final line = lines[i];
          if (line.kind == DiffLineKind.context) { add(split ? line : null, line); i++; continue; }
          final removed = <DiffCodeLine>[], added = <DiffCodeLine>[];
          while (i < lines.length && lines[i].kind != DiffLineKind.context) {
            final item = lines[i++];
            (item.kind == DiffLineKind.deletion ? removed : added).add(item);
          }
          if (split) {
            for (var j = 0; j < math.max(removed.length, added.length); j++) {
              add(j < removed.length ? removed[j] : null, j < added.length ? added[j] : null);
            }
          } else {
            for (var j = 0; j < removed.length; j++) { add(null, removed[j], counterpart: j < added.length ? added[j] : null); }
            for (var j = 0; j < added.length; j++) { add(null, added[j], counterpart: j < removed.length ? removed[j] : null); }
          }
        }
      }
    }
    var maximum = 0;
    for (final row in rows) { maximum = math.max(maximum, math.max(row.left?.oldLine ?? 0, row.right?.newLine ?? row.right?.oldLine ?? 0)); }
    _numberColumnWidth = math.max(40, maximum.toString().length * 7.3 + 8);
    _rows = List.unmodifiable(rows); _layout = null;
  }

  void _ensurePatch(ChangedFile file) {
    if (!widget.active || _reads[file.path]?.generation == _generation) return;
    _reads[file.path] = _patchTransition(_reads[file.path], _PatchPending(_generation, _reads[file.path]?.content));
    _queue.add(file);
    scheduleMicrotask(_pump);
  }

  void _pump() {
    if (!mounted || !widget.active) return;
    while (_running < 3 && _queue.isNotEmpty) {
      final file = _queue.removeAt(0), generation = _generation;
      final token = CancellationToken(); _tokens[file.path] = token;
      _running++;
      unawaited(_load(file, generation, token));
    }
  }

  Future<void> _load(ChangedFile file, int generation, CancellationToken token) async {
    final pending = _reads[file.path];
    bool current() => mounted && widget.active && generation == _generation && identical(_tokens[file.path], token) && !token.isCancelled;
    try {
      final load = widget.loadPatch;
      final result = load == null ? (file: file, truncated: false) : await load(file.path, _hideWhitespace, token);
      token.throwIfCancelled();
      if (!current()) return;
      if (result.truncated) throw const FormatException('This diff exceeds the preview limit. The incomplete patch is not displayed.');
      final raw = result.file.diff;
      if (_retainedBytes - (pending?.patch?.raw.length ?? 0) * 2 + raw.length * 2 > 32 * 1024 * 1024) {
        throw const FormatException('Preview memory limit reached. Close and reopen Changes to read again.');
      }
      final patch = DiffPatch.parse(raw, emptyMessage: _hideWhitespace ? 'No changes beyond white space' :
        file.kind == 'rename' ? 'File renamed without content changes' : file.kind == 'add' ? 'Empty file added' :
        file.kind == 'delete' ? 'File deleted without content changes' : 'No content changes (file metadata may have changed)');
      final syntax = await _syntax.highlight(patch, file.path, file.oldPath, token);
      token.throwIfCancelled();
      if (!current()) return;
      _rememberAnchor();
      _retainedBytes += raw.length * 2 - (pending?.patch?.raw.length ?? 0) * 2;
      _reads[file.path] = _patchTransition(_reads[file.path], _PatchReady(generation, _PatchContent(patch, syntax)));
      _measurePatch(patch);
      setState(_rebuildRows);
    } on CancelledException {
      // Hidden, superseded or disposed views cannot publish a stale patch.
    } catch (error) {
      if (current()) {
        _rememberAnchor();
        _reads[file.path] = _patchTransition(_reads[file.path], _PatchFailed(generation, pending?.content, '$error'));
        setState(_rebuildRows);
      }
    } finally {
      if (identical(_tokens[file.path], token)) _tokens.remove(file.path);
      token.cancel(); _running--; _pump();
    }
  }

  void _measurePatch(DiffPatch patch) {
    final sample = TextPainter(text: const TextSpan(text: '0', style: _code), textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling)..layout();
    final characterWidth = sample.width; sample.dispose();
    for (final hunk in patch.hunks) {
      for (final line in hunk.lines) {
        final text = expandDiffTabs(line.text);
        if (text.length * characterWidth <= _longest && !text.runes.any((rune) => rune > 127)) continue;
        final painter = TextPainter(text: TextSpan(text: text, style: _code), textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling)..layout();
        _longest = math.max(_longest, painter.width); painter.dispose();
      }
    }
  }

  void _scrolled() {
    final layout = _layout;
    if (layout == null || _rows.isEmpty || !_vertical.hasClients) return;
    _path = _rows[layout.indexAt(_vertical.offset)].file.path;
    _selected.value = _path;
  }

  void _jump(ChangedFile file, {bool notify = true}) {
    _reveal = file.path; _path = file.path; _selected.value = file.path;
    setState(() {
      _rememberAnchor(); _collapsed.remove(file.path); _collapsed.add('open:${file.path}');
      _rebuildRows(); _ensurePatch(file);
    });
    if (notify) widget.onSelect?.call(file.path);
  }

  bool _isCollapsed(String path) => _collapsed.contains(path) || _allCollapsed && !_collapsed.contains('open:$path');
  void _toggle(ChangedFile file) {
    _rememberAnchor();
    setState(() {
      final key = _allCollapsed ? 'open:${file.path}' : file.path;
      if (!_collapsed.remove(key)) _collapsed.add(key);
      _rebuildRows();
    });
  }
  void _toggleAll() {
    _rememberAnchor();
    final expanded = widget.files.any((file) => !_isCollapsed(file.path));
    setState(() { _allCollapsed = expanded; _collapsed.clear(); _rebuildRows(); });
  }
  void _presentation({String? mode, bool? wrap, bool? words}) {
    _rememberAnchor();
    setState(() { _mode = mode ?? _mode; _wrap = wrap ?? _wrap; _wordDiffs = words ?? _wordDiffs; _rebuildRows(); });
  }
  void _options(String value) {
    switch (value) {
      case 'collapse': _toggleAll();
      case 'words': _presentation(words: !_wordDiffs);
      case 'whitespace':
        _rememberAnchor();
        setState(() { _hideWhitespace = !_hideWhitespace; _invalidate(retain: false); });
    }
  }

  @override
  void dispose() {
    _generation++; _queue.clear();
    for (final token in _tokens.values) { token.cancel(); }
    _tokens.clear();
    final highlighter = _highlighter; _highlighter = null;
    if (highlighter != null) unawaited(highlighter.dispose());
    _filter.dispose(); _selected.dispose(); _vertical.dispose(); _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final files = widget.files, expanded = files.any((file) => !_isCollapsed(file.path));
    return ColoredBox(color: desktopSurface, child: Column(children: [
      Container(height: 40, padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: desktopBorder))),
        child: LayoutBuilder(builder: (context, constraints) => Row(children: [
          if (widget.comparison case final comparison?) comparison
          else const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: Text('Changes', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500))),
          if (constraints.maxWidth >= 440) ...[
            const SizedBox(width: 12), Text('${files.length} ${files.length == 1 ? 'file' : 'files'}', style: const TextStyle(fontSize: 12, color: desktopTertiary)),
          ],
          const Spacer(),
          if (constraints.maxWidth >= 550) ...[
            DiffStat(additions: files.fold(0, (sum, file) => sum + file.additions), deletions: files.fold(0, (sum, file) => sum + file.deletions)),
            const SizedBox(width: 8),
          ],
          _ReviewAction(label: expanded ? 'Collapse all diffs' : 'Expand all diffs',
            icon: expanded ? Icons.unfold_less_rounded : Icons.unfold_more_rounded, onPressed: files.isEmpty ? null : _toggleAll),
          SizedBox.square(dimension: 28, child: PopupMenuButton<ChangedFile>(tooltip: 'Jump to file',
            onSelected: _jump, padding: EdgeInsets.zero, iconSize: 16, icon: const Icon(Icons.list_alt_outlined, size: 16),
            itemBuilder: (_) => [for (final file in files) PopupMenuItem(value: file, height: 32,
              child: Text(file.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)))])),
          _ReviewAction(label: _mode == 'unified' ? 'Switch to split diff' : _mode == 'split' ? 'Switch to Auto diff' : 'Auto diff: switch to unified diff',
            icon: _mode == 'unified' ? Icons.view_agenda_outlined : _mode == 'split' ? Icons.vertical_split_outlined : Icons.auto_awesome_mosaic_outlined,
            onPressed: () => _presentation(mode: switch (_mode) { 'unified' => 'split', 'split' => 'auto', _ => 'unified' })),
          _ReviewAction(label: 'Word wrap', icon: Icons.wrap_text, selected: _wrap, onPressed: () => _presentation(wrap: !_wrap)),
          if (widget.onRefresh != null) _ReviewAction(label: 'Refresh changes', icon: Icons.refresh_rounded,
            onPressed: widget.loading ? null : () => unawaited(widget.onRefresh!())),
          SizedBox.square(dimension: 28, child: PopupMenuButton<String>(tooltip: 'Changes options', onSelected: _options, padding: EdgeInsets.zero,
            position: PopupMenuPosition.under, icon: const Icon(Icons.more_horiz, size: 17), itemBuilder: (_) => [
              PopupMenuItem(value: 'collapse', height: 32, child: Text(expanded ? 'Collapse all diffs' : 'Expand all diffs', style: const TextStyle(fontSize: 12))),
              CheckedPopupMenuItem(value: 'whitespace', height: 32, checked: _hideWhitespace, child: const Text('Hide white space', style: TextStyle(fontSize: 12))),
              CheckedPopupMenuItem(value: 'words', height: 32, checked: _wordDiffs, child: const Text('Word diffs', style: TextStyle(fontSize: 12))),
            ])),
        ]))),
      if (widget.loading) const LinearProgressIndicator(minHeight: 2),
      if (widget.error case final error?) Padding(padding: const EdgeInsets.all(8), child: Row(children: [
        const Icon(Icons.info_outline, size: 14, color: desktopError), const SizedBox(width: 8),
        Expanded(child: Text(error, style: const TextStyle(fontSize: 12, color: desktopSecondary))),
        if (widget.onRefresh != null) TextButton(onPressed: () => unawaited(widget.onRefresh!()), child: const Text('Retry')),
      ])),
      Expanded(child: files.isEmpty ? Center(child: Padding(padding: const EdgeInsets.all(24),
        child: Text(widget.loading ? 'Loading changes…' : widget.emptyLabel, textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: desktopSecondary))))
        : LayoutBuilder(builder: (context, constraints) => Row(children: [
          if (constraints.maxWidth >= 760) _fileList(files),
          Expanded(child: _body(constraints.maxWidth >= 760 ? constraints.maxWidth - 232 : constraints.maxWidth)),
        ]))),
    ]));
  }

  Widget _fileList(List<ChangedFile> files) {
    const palette = _palette;
    final query = _filter.text.toLowerCase();
    final filtered = files.where((file) => file.path.toLowerCase().contains(query) || (file.oldPath?.toLowerCase().contains(query) ?? false)).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return Container(width: 232, decoration: BoxDecoration(color: palette.surface,
      border: BorderDirectional(end: BorderSide(color: palette.border))),
      child: Column(children: [
        Padding(padding: const EdgeInsets.all(8), child: SizedBox(height: 28, child: TextField(controller: _filter,
          style: const TextStyle(fontSize: 12), decoration: InputDecoration(hintText: 'Filter changed files',
            hintStyle: TextStyle(color: palette.foregroundTertiary, fontSize: 12), prefixIcon: Icon(Icons.search, size: 14, color: palette.foregroundTertiary),
            prefixIconConstraints: const BoxConstraints(minWidth: 28), contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            filled: true, fillColor: palette.secondaryBackground, border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none))))),
        Expanded(child: ValueListenableBuilder<String?>(valueListenable: _selected, builder: (context, selected, _) => ListView.builder(
          padding: const EdgeInsets.fromLTRB(6, 0, 6, 8), itemCount: filtered.length,
          itemBuilder: (context, i) {
            final file = filtered[i], parent = p.posix.dirname(filtered[i].path);
            return Padding(padding: const EdgeInsets.only(bottom: 2), child: Tooltip(message: file.oldPath == null ? file.path : '${file.oldPath} → ${file.path}',
              child: Material(color: selected == file.path || selected == null && i == 0 ? palette.secondaryBackground : Colors.transparent,
                borderRadius: BorderRadius.circular(6), child: InkWell(borderRadius: BorderRadius.circular(6), onTap: () => _jump(file),
                  child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7), child: Row(children: [
                    SizedBox(width: 16, child: Text(switch (file.kind) { 'add' => 'A', 'delete' => 'D', 'rename' => 'R', _ => 'M' }, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500,
                      color: file.kind == 'add' ? _added : file.kind == 'delete' ? _deleted : palette.foregroundTertiary))),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(p.posix.basename(file.path), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                      if (parent != '.') Text(parent, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: palette.foregroundTertiary)),
                    ])),
                    const SizedBox(width: 6), _Stats(file.additions, file.deletions, size: 10),
                  ]))))));
          }))),
      ]));
  }

  Widget _body(double width) {
    final previous = _layout;
    if (previous == null || previous.width != width || previous.wrap != _wrap) {
      if (previous != null) _rememberAnchor();
      final layout = _layout = _DiffLayout(_rows, width, _wrap, _numberColumnWidth);
      final reveal = _reveal, anchor = _anchor;
      _anchor = null;
      final index = reveal == null ? anchor == null ? -1 : _rows.indexWhere((r) => r.id == anchor.$1)
        : _rows.indexWhere((r) => r.id == 'file:$reveal');
      if (index >= 0) {
        final offset = layout.offset(index) + (reveal != null ? 0 : (anchor!.$2).clamp(0, math.max(0, layout.height(index) - 1)));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !identical(_layout, layout) || !_vertical.hasClients) return;
          _vertical.jumpTo(offset.clamp(0, _vertical.position.maxScrollExtent));
          _scrolled();
          // Keep explicit navigation until the matching layout actually lands.
          // Another file can finish loading before this frame's callback.
          if (reveal != null && _reveal == reveal && _reads[reveal]?.patch != null) _reveal = null;
        });
      }
    }
    final layout = _layout!;
    final rows = _rows;
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].id: i};
    final hasSplit = _rows.any((row) => row.split);
    final textWidth = math.max(1.0, (hasSplit ? (width - 1) / 2 - _numberColumnWidth - 32 : width - _numberColumnWidth * 2 - 32));
    final overflow = _wrap ? 0.0 : math.max(0.0, _longest - textWidth);
    return Column(children: [
      Expanded(child: SelectionArea(child: Scrollbar(controller: _vertical, child: ListView.builder(
        controller: _vertical, padding: const EdgeInsets.only(bottom: 16), itemCount: rows.length,
        findChildIndexCallback: (key) => key is ValueKey<String> ? indices[key.value] : null,
        itemExtentBuilder: (index, _) => layout.height(index),
        itemBuilder: (context, index) {
          final row = rows[index];
          return KeyedSubtree(key: ValueKey(row.id), child: Builder(builder: (context) {
          if (row.kind != _RowKind.file) { _ensurePatch(row.file); }
          if (row.kind == _RowKind.file) {
            final collapsed = _isCollapsed(row.file.path);
            if (!collapsed) { _ensurePatch(row.file); }
            return _fileHeader(row.file, collapsed);
          }
          if (row.kind == _RowKind.hunk) { return SelectionContainer.disabled(child: Container(
            alignment: AlignmentDirectional.centerStart, padding: const EdgeInsets.symmetric(horizontal: 16),
            color: const Color(0xfff3f6f9), child: Text(row.label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: _code.copyWith(fontSize: 11, color: _palette.foregroundTertiary)))); }
          if (row.kind == _RowKind.message) { return Container(alignment: AlignmentDirectional.centerStart,
            padding: const EdgeInsets.symmetric(horizontal: 20), color: _palette.surfaceUnder,
            child: Text(row.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: _palette.foregroundSecondary))); }
          return _codeRow(row, layout.height(index));
          }));
        })))),
      if (!_wrap && overflow > 0) SizedBox(height: 12, child: Scrollbar(controller: _horizontal,
        thumbVisibility: true, notificationPredicate: (notification) => notification.metrics.axis == Axis.horizontal,
        child: SingleChildScrollView(controller: _horizontal, scrollDirection: Axis.horizontal,
          child: SizedBox(width: width + overflow, height: 1)))),
    ]);
  }

  Widget _fileHeader(ChangedFile file, bool collapsed) {
    const palette = _palette;
    return SelectionContainer.disabled(child: Container(decoration: BoxDecoration(color: palette.surface,
      border: Border(bottom: BorderSide(color: palette.border))),
      padding: const EdgeInsetsDirectional.only(start: 8, end: 8), child: Row(children: [
        FileIcon(file.path, size: 15),
        _ReviewAction(label: collapsed ? 'Expand ${file.path}' : 'Collapse ${file.path}', icon: collapsed ? Icons.chevron_right : Icons.expand_more, onPressed: () => _toggle(file)),
        const SizedBox(width: 4),
        Expanded(child: Tooltip(message: file.oldPath == null ? file.path : '${file.oldPath} → ${file.path}',
          child: InkWell(onTap: () => _toggle(file), child: Text(file.oldPath == null ? file.path : '${file.oldPath} → ${file.path}',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))))),
        const SizedBox(width: 8), _Stats(file.additions, file.deletions), const SizedBox(width: 8),
        ConversationCopyButton(text: _reads[file.path]?.patch?.raw ?? '', label: 'Copy file diff', compact: true),
        if (file.kind != 'delete') _ReviewAction(label: 'Open file', icon: Icons.open_in_new_rounded, onPressed: () {
          final location = conversationFileLocation(file.path, widget.directory);
          if (location != null) ConversationFileScope.open(context, location);
        }),
      ])));
  }

  Widget _codeRow(_DiffRow row, double height) => row.split ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Expanded(child: _cell(row.file, row.left, row.right, height, split: true, left: true)),
    Container(width: 1, color: _palette.borderLight),
    Expanded(child: _cell(row.file, row.right, row.left, height, split: true)),
  ]) : _cell(row.file, row.right, row.counterpart, height);

  Widget _cell(ChangedFile file, DiffCodeLine? line, DiffCodeLine? counterpart, double height, {bool split = false, bool left = false}) {
    const palette = _palette;
    final kind = line?.kind;
    final changed = kind != null && kind != DiffLineKind.context;
    final base = kind == DiffLineKind.addition ? _added : _deleted;
    final background = line == null ? palette.surfaceUnder : changed ? Color.alphaBlend(base.withValues(alpha: .08), palette.surface) : palette.surface;
    final marker = kind == DiffLineKind.addition ? '+' : kind == DiffLineKind.deletion ? '−' : '';
    final text = expandDiffTabs(line?.text ?? '');
    final highlight = _wordDiffs && changed && counterpart != null ? _changedRange(text, expandDiffTabs(counterpart.text)) : null;
    final syntax = _reads[file.path]?.syntax;
    final span = line != null && syntax != null ? syntax.span(line, text, changed: highlight, background: base.withValues(alpha: .18))
      : highlight == null ? TextSpan(text: text) : TextSpan(children: [
      TextSpan(text: text.substring(0, highlight.$1)),
      TextSpan(text: text.substring(highlight.$1, highlight.$2), style: TextStyle(backgroundColor: base.withValues(alpha: .18))),
      TextSpan(text: text.substring(highlight.$2)),
    ]);
    Widget numbers() => SelectionContainer.disabled(child: Container(height: height, color: changed ? base.withValues(alpha: .045) : null,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (!split) _number(line?.oldLine),
        _number(split && left ? line?.oldLine : line?.newLine),
        SizedBox(width: 20, child: Text(marker, textAlign: TextAlign.center, style: _code.copyWith(color: changed ? base : palette.foregroundTertiary))),
      ])));
    return Semantics(label: line == null ? 'No corresponding line' : '${kind == DiffLineKind.context ? 'Context' : kind == DiffLineKind.addition ? 'Added' : 'Removed'} line ${line.newLine ?? line.oldLine}',
      child: ColoredBox(color: background, child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        numbers(),
        Expanded(child: LayoutBuilder(builder: (context, constraints) {
          final content = Padding(padding: const EdgeInsetsDirectional.only(end: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text.rich(span, style: _code, textScaler: TextScaler.noScaling, softWrap: _wrap, maxLines: _wrap ? null : 1),
            if (line?.noNewline == true) SelectionContainer.disabled(child: Text('No newline at end of file',
              style: _code.copyWith(fontSize: 10, color: palette.foregroundTertiary))),
          ]));
          if (_wrap) return content;
          return ClipRect(child: AnimatedBuilder(animation: _horizontal, child: content, builder: (context, child) =>
            OverflowBox(alignment: AlignmentDirectional.topStart, minWidth: math.max(constraints.maxWidth, _longest + 12),
              maxWidth: math.max(constraints.maxWidth, _longest + 12),
              child: Transform.translate(offset: Offset(-(_horizontal.hasClients ? _horizontal.offset : 0.0), 0), child: child))));
        })),
      ])));
  }

  Widget _number(int? number) => SizedBox(width: _numberColumnWidth, child: Padding(padding: const EdgeInsetsDirectional.only(end: 8),
    child: Text(number?.toString() ?? '', maxLines: 1, textAlign: TextAlign.end, textScaler: TextScaler.noScaling,
      style: _code.copyWith(color: _palette.foregroundTertiary, fontFeatures: const [FontFeature.tabularFigures()]))));
}

class _Stats extends StatelessWidget {
  const _Stats(this.additions, this.deletions, {this.size = 12});
  final int? additions, deletions;
  final double size;
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    if (additions == null && deletions == null) Text('Binary', style: TextStyle(fontSize: size, color: _palette.foregroundTertiary))
    else ...[
      Text('+${additions ?? 0}', style: TextStyle(fontSize: size, color: _added, letterSpacing: -.2, fontFeatures: const [FontFeature.tabularFigures()])),
      const SizedBox(width: 4),
      Text('−${deletions ?? 0}', style: TextStyle(fontSize: size, color: _deleted, letterSpacing: -.2, fontFeatures: const [FontFeature.tabularFigures()])),
    ],
  ]);
}

class _ReviewAction extends StatelessWidget {
  const _ReviewAction({required this.label, required this.icon, this.onPressed, this.selected = false});
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;
  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: 28, child: IconButton(
    tooltip: label, onPressed: onPressed, padding: EdgeInsets.zero, iconSize: 16,
    style: IconButton.styleFrom(backgroundColor: selected ? _palette.secondaryBackground : Colors.transparent,
      foregroundColor: _palette.foregroundSecondary, disabledForegroundColor: _palette.foregroundTertiary.withValues(alpha: .4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)), minimumSize: const Size.square(28),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap, splashFactory: NoSplash.splashFactory), icon: Icon(icon)));
}

/// A shared measured layout gives lazy rows exact wrapped heights and permits
/// file navigation without building every source line or losing the anchor.
class _DiffLayout {
  _DiffLayout(this.rows, this.width, this.wrap, [this.numberWidth]);
  final List<_DiffRow> rows;
  final double width;
  final bool wrap;
  final double? numberWidth;
  final _heights = <int, double>{};
  final _offsets = <double>[0];
  double height(int index) => _heights.putIfAbsent(index, () {
    final row = rows[index];
    if (row.kind == _RowKind.file) return 42;
    if (row.kind == _RowKind.hunk) return 28;
    if (row.kind == _RowKind.message) return 60;
    double measure(DiffCodeLine? line) {
      if (line == null) return 22;
      var height = 22.0;
      if (wrap && line.text.isNotEmpty) {
        final available = math.max(1.0, row.split ? (width - 1) / 2 - (numberWidth ?? 40) - 32 : width - (numberWidth ?? 40) * 2 - 32);
        final painter = TextPainter(text: TextSpan(text: expandDiffTabs(line.text), style: _code), textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling)..layout(maxWidth: available);
        height = math.max(height, painter.height); painter.dispose();
      }
      return height + (line.noNewline ? 18 : 0);
    }
    return row.split ? math.max(measure(row.left), measure(row.right)) : measure(row.right);
  });
  double offset(int index) {
    while (_offsets.length <= index) { _offsets.add(_offsets.last + height(_offsets.length - 1)); }
    return _offsets[index];
  }
  int indexAt(double value) {
    if (rows.isEmpty) return 0;
    while (_offsets.last <= value && _offsets.length <= rows.length) { offset(_offsets.length); }
    var low = 0, high = math.min(rows.length, _offsets.length - 1);
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (_offsets[middle] <= value) { low = middle; } else { high = middle - 1; }
    }
    return low.clamp(0, rows.length - 1);
  }
}

/// Bounded inline emphasis: preserve word boundaries around the differing
/// middle. Git still owns line pairing. Avoid quadratic work on long lines.
(int, int)? _changedRange(String text, String other) {
  if (text.isEmpty || other.isEmpty || text == other || text.length > 8192 || other.length > 8192) return null;
  var start = 0, end = text.length, otherEnd = other.length;
  while (start < end && start < otherEnd && text.codeUnitAt(start) == other.codeUnitAt(start)) { start++; }
  while (end > start && otherEnd > start && text.codeUnitAt(end - 1) == other.codeUnitAt(otherEnd - 1)) { end--; otherEnd--; }
  bool word(int i) => i >= 0 && i < text.length && RegExp(r'[\w$]').hasMatch(text[i]);
  while (start > 0 && word(start - 1) && word(start)) { start--; }
  while (end < text.length && word(end - 1) && word(end)) { end++; }
  // Never split UTF-16 surrogate pairs in a TextSpan boundary.
  if (start > 0 && start < text.length && text.codeUnitAt(start) >= 0xdc00 && text.codeUnitAt(start) <= 0xdfff) start--;
  if (end < text.length && text.codeUnitAt(end) >= 0xdc00 && text.codeUnitAt(end) <= 0xdfff) end++;
  return start == end ? null : (start, end);
}

// Conversation patches describe an immutable turn, so whitespace filtering
// operates on those exact hunks instead of rereading today's working tree.
List<DiffHunk> _withoutWhitespace(List<DiffHunk> hunks) {
  final result = <DiffHunk>[];
  final spaces = RegExp(r'\s+');
  for (final hunk in hunks) {
    final lines = <DiffCodeLine>[];
    for (var i = 0; i < hunk.lines.length;) {
      if (hunk.lines[i].kind == DiffLineKind.context) { lines.add(hunk.lines[i++]); continue; }
      final removed = <DiffCodeLine>[], added = <DiffCodeLine>[];
      while (i < hunk.lines.length && hunk.lines[i].kind != DiffLineKind.context) {
        final line = hunk.lines[i++];
        (line.kind == DiffLineKind.deletion ? removed : added).add(line);
      }
      final same = removed.length == added.length && List.generate(removed.length, (j) => j).every((j) =>
        removed[j].text.replaceAll(spaces, '') == added[j].text.replaceAll(spaces, '') && removed[j].noNewline == added[j].noNewline);
      if (same) {
        for (var j = 0; j < added.length; j++) {
          lines.add(DiffCodeLine(added[j].text, DiffLineKind.context,
            oldLine: removed[j].oldLine, newLine: added[j].newLine, noNewline: added[j].noNewline));
        }
      } else { lines.addAll(removed); lines.addAll(added); }
    }
    if (lines.any((line) => line.kind != DiffLineKind.context)) {
      result.add(DiffHunk(header: hunk.header, oldStart: hunk.oldStart, newStart: hunk.newStart, lines: List.unmodifiable(lines)));
    }
  }
  return result;
}
