import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:protocol/protocol.dart';
import 'connection.dart';

import 'appearance.dart';
import 'file_icon.dart';
import 'file_reference.dart';

typedef _FolderEntry = ({String name, String path, bool directory});
typedef _FolderRow = ({String path, int depth, _FolderEntry? entry});

sealed class _FolderState { const _FolderState(); }
final class _FolderIdle extends _FolderState { const _FolderIdle(); }
final class _FolderLoading extends _FolderState { const _FolderLoading(); }
final class _FolderReady extends _FolderState {
  const _FolderReady(this.entries);
  final List<_FolderEntry> entries;
}
final class _FolderFailed extends _FolderState { const _FolderFailed(); }

_FolderState _transition(_FolderState current, _FolderState next) => switch ((current, next)) {
  (_, _FolderLoading() || _FolderIdle()) => next,
  (_FolderLoading(), _FolderReady() || _FolderFailed()) => next,
  _ => throw StateError('Invalid folder viewer transition'),
};

Future<List<_FolderEntry>> _readFolder(AgentClient client, String path, CancellationToken cancellation) async {
  final result = await client.fileSystemRequest('fs/readDirectory', path, cancellation: cancellation);
  return computeCancellable(() {
    final entries = <_FolderEntry>[];
    for (final value in result['entries'] as List<Object?>) {
      final entry = jsonObject(value);
      final name = requiredString(entry, 'fileName');
      if (name.isEmpty || name == '.' || name == '..' || p.basename(name) != name) {
        throw const FormatException('Invalid directory entry');
      }
      entries.add((name: name, path: p.join(path, name), directory: entry['isDirectory'] == true));
    }
    entries.sort((a, b) {
      if (a.directory != b.directory) return a.directory ? -1 : 1;
      final order = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return order == 0 ? a.name.compareTo(b.name) : order;
    });
    return List<_FolderEntry>.unmodifiable(entries);
  }, cancellation);
}

/// Lists only the root and folders the user expands, on the selected server.
class FolderViewer extends StatefulWidget {
  const FolderViewer({super.key, required this.client, required this.path,
    required this.active, this.reloadRequest = 0});
  final AgentClient client;
  final String path;
  final bool active;
  final int reloadRequest;

  @override
  State<FolderViewer> createState() => _FolderViewerState();
}

class _FolderViewerState extends State<FolderViewer> {
  final _folders = <String, _FolderState>{};
  final _reads = <String, CancellationToken>{};
  final _expanded = <String>{};
  String get _root => p.normalize(widget.path);

  @override
  void initState() {
    super.initState();
    if (widget.active) _resume(_root);
  }

  @override
  void didUpdateWidget(FolderViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client || oldWidget.path != widget.path) {
      _cancelReads((_) => true);
      _folders.clear();
      _expanded.clear();
    } else if (oldWidget.reloadRequest != widget.reloadRequest) {
      _cancelReads((_) => true);
      _folders.clear();
    }
    if (widget.active) {
      _resume(_root);
    } else {
      _cancelReads((_) => true);
    }
  }

  void _set(String path, _FolderState next) {
    _folders[path] = _transition(_folders[path] ?? const _FolderIdle(), next);
  }

  void _cancelReads(bool Function(String) matches) {
    for (final path in _reads.keys.where(matches).toList()) {
      _reads.remove(path)!.cancel();
      _set(path, const _FolderIdle());
    }
  }

  void _resume(String path) {
    final state = _folders[path] ?? const _FolderIdle();
    if (state is _FolderIdle) unawaited(_load(path));
    if (state is _FolderReady) {
      for (final entry in state.entries) {
        if (entry.directory && _expanded.contains(entry.path)) _resume(entry.path);
      }
    }
  }

  Future<void> _load(String path) async {
    if (!widget.active) return;
    _reads.remove(path)?.cancel();
    final read = _reads[path] = CancellationToken();
    setState(() => _set(path, const _FolderLoading()));
    try {
      final entries = await _readFolder(widget.client, path, read);
      read.throwIfCancelled();
      if (!mounted || !identical(_reads[path], read)) return;
      setState(() => _set(path, _FolderReady(entries)));
      _resume(path);
    } on CancelledException {
      // Collapsing a folder, hiding the panel or closing it cancels its reads.
    } catch (_) {
      if (mounted && !read.isCancelled && identical(_reads[path], read)) {
        setState(() => _set(path, const _FolderFailed()));
      }
    } finally {
      if (identical(_reads[path], read)) _reads.remove(path);
    }
  }

  void _toggle(String path) {
    setState(() {
      if (_expanded.remove(path)) {
        _cancelReads((candidate) => candidate == path || p.isWithin(path, candidate));
      } else {
        _expanded.add(path);
      }
    });
    if (_expanded.contains(path)) _resume(path);
  }

  Iterable<_FolderRow> _rows(String path, int depth) sync* {
    final state = _folders[path] ?? const _FolderIdle();
    if (state is! _FolderReady || state.entries.isEmpty) {
      yield (path: path, depth: depth, entry: null);
      return;
    }
    for (final entry in state.entries) {
      yield (path: entry.path, depth: depth, entry: entry);
      if (entry.directory && _expanded.contains(entry.path)) yield* _rows(entry.path, depth + 1);
    }
  }

  Widget _status(_FolderRow row) {
    final state = _folders[row.path] ?? const _FolderIdle();
    final failed = state is _FolderFailed;
    final loading = state is _FolderLoading || state is _FolderIdle;
    return Padding(padding: EdgeInsets.fromLTRB(20 + row.depth * 16, 8, 12, 8),
      child: Row(children: [
        if (loading) ...[
          const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
          const SizedBox(width: 8),
        ],
        Expanded(child: Text(loading ? 'Loading folder…' : failed ? 'Could not read this folder.'
          : row.depth == 0 ? 'This folder is empty.' : 'Empty folder',
          style: const TextStyle(fontSize: 12, color: desktopTertiary))),
        if (failed) TextButton(onPressed: () => unawaited(_load(row.path)), child: const Text('Retry')),
      ]));
  }

  Widget _entry(_FolderRow row, _FolderEntry entry) {
    final expanded = _expanded.contains(entry.path);
    return Tooltip(message: entry.path, child: Semantics(button: true,
      expanded: entry.directory ? expanded : null,
      child: InkWell(key: ValueKey('folder-entry:${entry.path}'),
        onTap: () => entry.directory ? _toggle(entry.path)
          : ConversationFileScope.open(context, (path: entry.path, line: null)),
        child: SizedBox(height: 30, child: Padding(
          padding: EdgeInsets.only(left: 12 + row.depth * 16, right: 16),
          child: Row(children: [
            SizedBox(width: 18, child: entry.directory
              ? Icon(expanded ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_right_rounded,
                  size: 16, color: desktopTertiary) : null),
            FileIcon(entry.directory ? '${entry.path}/' : entry.path, expanded: expanded),
            const SizedBox(width: 8),
            Expanded(child: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: desktopForeground))),
          ]))))));
  }

  @override
  void dispose() {
    for (final read in _reads.values) { read.cancel(); }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows(_root, 0).toList(growable: false), root = _folders[_root];
    return Column(children: [
      Expanded(child: ListView.builder(key: PageStorageKey('folder-tree:$_root'),
        padding: const EdgeInsets.symmetric(vertical: 8), itemCount: rows.length,
        itemBuilder: (context, index) {
          final row = rows[index], entry = row.entry;
          return entry == null ? _status(row) : _entry(row, entry);
        })),
      Container(height: 28, padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: desktopBorder, width: .5))),
        child: Row(children: [
          FileIcon('$_root/', size: 12), const SizedBox(width: 6),
          if (root is _FolderReady) Text('${root.entries.length} item${root.entries.length == 1 ? '' : 's'}',
            style: const TextStyle(fontSize: 11, color: desktopTertiary)),
          const Spacer(),
          if (_expanded.isNotEmpty) SizedBox.square(dimension: 24, child: IconButton(
            tooltip: 'Collapse folders', padding: EdgeInsets.zero,
            icon: const Icon(Icons.unfold_less_rounded, size: 16, color: desktopSecondary),
            onPressed: () => setState(() {
              _cancelReads((path) => path != _root);
              _expanded.clear();
            }))),
        ])),
    ]);
  }
}
