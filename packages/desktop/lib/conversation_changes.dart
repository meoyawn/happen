import 'dart:async';

import 'package:flutter/material.dart';

import 'appearance.dart';
import 'conversation_activity.dart';
import 'diff_viewer.dart';
import 'file_change.dart';
import 'file_icon.dart';
import 'session.dart';

class ConversationDiffScope extends InheritedWidget {
  const ConversationDiffScope({super.key, required this.onOpen, required super.child});
  final void Function(String source, String? path) onOpen;
  static void open(BuildContext context, String source, List<ChangedFile> files, {String? path}) {
    final scope = context.getInheritedWidgetOfExactType<ConversationDiffScope>();
    if (scope != null) { scope.onOpen(source, path); return; }
    unawaited(showDialog<void>(context: context, builder: (context) => Dialog(clipBehavior: Clip.antiAlias,
      child: SizedBox(width: 1100, height: 760, child: Column(children: [
        Align(alignment: Alignment.centerRight, child: IconButton(tooltip: 'Close diff',
          onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, size: 18))),
        Expanded(child: DiffViewer(files: files, selectedPath: path)),
      ])))));
  }
  @override
  bool updateShouldNotify(ConversationDiffScope oldWidget) => onOpen != oldWidget.onOpen;
}

class ConversationFileChangeActivity extends StatelessWidget {
  const ConversationFileChangeActivity({super.key, required this.tool, required this.onExpand, this.directory = ''});
  final ToolActivity tool;
  final VoidCallback onExpand;
  final String directory;
  @override
  Widget build(BuildContext context) {
    final input = tool.rawInput;
    final files = nativeFileChanges(input is Map ? input['changes'] : null);
    final active = tool.status == 'running', failed = tool.status == 'failed';
    return ConversationDisclosure(key: PageStorageKey('file-change:${tool.id}'),
      label: '${failed ? 'Failed to change' : active ? 'Changing' : 'Changed'} ${files.length} file${files.length == 1 ? '' : 's'}',
      fontSize: 14, timestamp: tool.startedAt, shimmer: active, onExpand: onExpand,
      color: failed ? const Color(0xffc10007) : conversationSecondary,
      icon: Icon(Icons.description_outlined, size: 16, color: failed ? const Color(0xffc10007) : conversationSecondary),
      builder: (context) => Padding(padding: const EdgeInsets.only(left: 26, top: 6, bottom: 8),
        child: ConversationChangedFiles(source: 'item:${tool.id}', files: files, directory: directory,
          notice: failed ? 'This patch failed. The preview shows the requested changes.' :
            tool.status == 'interrupted' ? 'This patch was interrupted.' : active ? 'Applying changes…' : null)));
  }
}

// T3 Code ChangedFilesTree.tsx: compact folders, aggregate stats and a full diff action.
class ConversationChangedFiles extends StatefulWidget {
  const ConversationChangedFiles({super.key, required this.source, required this.files, this.directory = '', this.notice});
  final String source, directory;
  final List<ChangedFile> files;
  final String? notice;
  @override
  State<ConversationChangedFiles> createState() => _ConversationChangedFilesState();
}

class _ConversationChangedFilesState extends State<ConversationChangedFiles> {
  bool _allExpanded = false;
  final _overrides = <String, bool>{};
  late List<_ChangeNode> _nodes = _changeTree(widget.files, widget.directory);

  @override
  void initState() {
    super.initState();
    final saved = PageStorage.maybeOf(context)?.readState(context, identifier: widget.source);
    if (saved is Map) {
      _allExpanded = saved['all'] == true;
      final overrides = saved['overrides'];
      if (overrides is Map) _overrides.addAll(overrides.cast<String, bool>());
    }
  }

  @override
  void didUpdateWidget(ConversationChangedFiles oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.files != widget.files || oldWidget.directory != widget.directory) {
      _nodes = _changeTree(widget.files, widget.directory);
    }
  }

  void _remember() => PageStorage.maybeOf(context)?.writeState(context,
    {'all': _allExpanded, 'overrides': Map<String, bool>.of(_overrides)}, identifier: widget.source);

  @override
  Widget build(BuildContext context) {
    final files = widget.files;
    if (files.isEmpty) return const SizedBox.shrink();
    final rows = <({ _ChangeNode node, int depth})>[];
    void visit(List<_ChangeNode> nodes, int depth) {
      for (final node in nodes) {
        rows.add((node: node, depth: depth));
        if (node.file == null && (_overrides[node.path] ?? _allExpanded)) visit(node.children, depth + 1);
      }
    }
    visit(_nodes, 0);
    final hasDirectories = _nodes.any((node) => node.file == null);
    return Material(color: conversationSurface, borderRadius: BorderRadius.circular(8), clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(12, 5, 6, 5), child: Row(children: [
          Expanded(child: Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('${files.length} changed file${files.length == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: conversationForeground)),
            DiffStat(additions: files.fold(0, (sum, file) => sum + file.additions),
              deletions: files.fold(0, (sum, file) => sum + file.deletions)),
          ])),
          if (hasDirectories) SizedBox.square(dimension: 28, child: IconButton(
            tooltip: _allExpanded ? 'Collapse all folders' : 'Expand all folders',
            padding: EdgeInsets.zero, iconSize: 15,
            onPressed: () => setState(() { _allExpanded = !_allExpanded; _overrides.clear(); _remember(); }),
            icon: Icon(_allExpanded ? Icons.unfold_less_rounded : Icons.unfold_more_rounded, color: conversationSecondary))),
          TextButton.icon(onPressed: () => ConversationDiffScope.open(context, widget.source, files, path: files.first.path),
            style: TextButton.styleFrom(foregroundColor: conversationSecondary, minimumSize: const Size(28, 28),
              padding: const EdgeInsets.symmetric(horizontal: 6), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            icon: const Icon(Icons.difference_outlined, size: 14),
            label: const Text('Open diff', style: TextStyle(fontSize: 12))),
        ])),
        if (widget.notice != null) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Text(widget.notice!, style: const TextStyle(fontSize: 11, color: conversationSecondary))),
        ConstrainedBox(constraints: const BoxConstraints(maxHeight: 280),
          child: ListView.builder(key: PageStorageKey('changed-files:${widget.source}'),
            shrinkWrap: true, primary: false, itemExtent: 28, padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            itemCount: rows.length, itemBuilder: (context, index) {
              final node = rows[index].node, file = node.file;
              final expanded = _overrides[node.path] ?? _allExpanded;
              return Tooltip(message: file == null ? node.path :
                  '${file.oldPath == null ? '' : '${file.oldPath} → '}${file.path}',
                child: InkWell(borderRadius: BorderRadius.circular(5),
                  onTap: () {
                    if (file != null) { ConversationDiffScope.open(context, widget.source, files, path: file.path); }
                    else { setState(() { _overrides[node.path] = !expanded; _remember(); }); }
                  },
                  child: Padding(padding: EdgeInsets.only(left: 4 + rows[index].depth * 14, right: 8),
                    child: Row(children: [
                      if (hasDirectories) SizedBox(width: 20, child: file == null
                        ? Icon(expanded ? Icons.keyboard_arrow_down_rounded : Icons.chevron_right_rounded,
                          size: 16, color: conversationSecondary) : null),
                      if (file == null) Icon(expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
                        size: 15, color: conversationSecondary)
                      else FileIcon(file.path, size: 15),
                      const SizedBox(width: 8),
                      Expanded(child: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 11, color: conversationSecondary))),
                      if (file != null && file.kind != 'update') Padding(padding: const EdgeInsets.only(left: 8),
                        child: Text(switch (file.kind) {'add' => 'A', 'delete' => 'D', 'rename' => 'R', _ => 'M'},
                          style: TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 10,
                            color: file.kind == 'add' ? diffAdded : file.kind == 'delete' ? diffRemoved : conversationSecondary))),
                      const SizedBox(width: 12),
                      DiffStat(additions: node.additions, deletions: node.deletions),
                    ]))));
            })),
      ]));
  }
}

class _ChangeNode {
  _ChangeNode(this.path, this.name, {this.file});
  final String path;
  String name;
  final ChangedFile? file;
  final children = <_ChangeNode>[];
  int additions = 0, deletions = 0;
}

List<_ChangeNode> _changeTree(List<ChangedFile> files, String directory) {
  final roots = <_ChangeNode>[], directories = <String, _ChangeNode>{};
  final normalizedRoot = directory.replaceAll(r'\', '/').replaceFirst(RegExp(r'/$'), '');
  for (final file in files) {
    var path = file.path.replaceAll(r'\', '/');
    if (normalizedRoot.isNotEmpty && path.startsWith('$normalizedRoot/')) path = path.substring(normalizedRoot.length + 1);
    final segments = path.split('/').where((segment) => segment.isNotEmpty).toList();
    if (segments.isEmpty) continue;
    var children = roots, prefix = '';
    for (final segment in segments.take(segments.length - 1)) {
      prefix = prefix.isEmpty ? segment : '$prefix/$segment';
      var node = directories[prefix];
      if (node == null) {
        node = _ChangeNode(prefix, segment);
        children.add(node); directories[prefix] = node;
      }
      node.additions += file.additions; node.deletions += file.deletions;
      children = node.children;
    }
    children.add(_ChangeNode(file.path, segments.last, file: file)
      ..additions = file.additions..deletions = file.deletions);
  }
  void compact(List<_ChangeNode> nodes) {
    nodes.sort((a, b) => a.file == null && b.file != null ? -1 : a.file != null && b.file == null ? 1
      : a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i];
      while (node.file == null && node.children.length == 1 && node.children.single.file == null) {
        final child = node.children.single;
        child.name = '${node.name}/${child.name}';
        nodes[i] = node = child;
      }
      compact(node.children);
    }
  }
  compact(roots);
  return roots;
}
