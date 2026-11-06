import 'dart:async';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'diff_viewer.dart';
import 'file_change.dart';
import 'git_actions_state.dart';

/// Current checkout changes, loaded per file so large repositories stay bounded.
class WorkspaceChanges extends StatefulWidget {
  const WorkspaceChanges({super.key, required this.controller});
  final GitActionsController controller;
  @override
  State<WorkspaceChanges> createState() => _WorkspaceChangesState();
}

class _WorkspaceChangesState extends State<WorkspaceChanges> {
  final _lifetime = CancellationToken();
  CancellationToken? _read;
  late Future<({ChangedFile file, bool truncated})> _diff;
  String? _path;
  int _revision = 0;
  @override
  void initState() { super.initState(); _select(widget.controller.state.repository?.files.firstOrNull?.path); }
  void _select(String? path) {
    _read?.cancel(); _read = null;
    _path = path; _revision++;
    if (path == null) return;
    final token = _read = CancellationToken();
    _diff = widget.controller.diff(path, token.merge(_lifetime));
  }
  Future<void> _refresh() async {
    await widget.controller.refresh(force: true);
    if (!mounted) return;
    final files = widget.controller.state.repository?.files;
    setState(() => _select(files?.any((file) => file.path == _path) == true ? _path : files?.firstOrNull?.path));
  }
  @override
  void dispose() { _lifetime.cancel(); _read?.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Column(children: [
    Row(children: [
      const SizedBox(width: 16),
      const Expanded(child: Text('Working tree changes', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
      IconButton(tooltip: 'Refresh changes', onPressed: () => unawaited(_refresh()),
        icon: const Icon(Icons.refresh_rounded, size: 17)),
    ]),
    Expanded(child: _path == null ? const Center(child: Text('No file changes', style: TextStyle(color: opencodeMuted)))
      : FutureBuilder<({ChangedFile file, bool truncated})>(future: _diff, builder: (context, snapshot) {
        final repo = widget.controller.state.repository!;
        final loaded = snapshot.connectionState == ConnectionState.done ? snapshot.data : null;
        final files = <ChangedFile>[for (final file in repo.files)
          if (loaded?.file.path == file.path) loaded!.file
          else (path: file.path, oldPath: file.previousPath, kind: 'update', diff: '',
            additions: file.additions, deletions: file.deletions)];
        return Column(children: [
          if (snapshot.connectionState != ConnectionState.done) const LinearProgressIndicator(minHeight: 2),
          if (snapshot.hasError) Padding(padding: const EdgeInsets.all(12),
            child: Text('${snapshot.error}', style: const TextStyle(fontSize: 12, color: Color(0xffc23838)))),
          if (loaded?.truncated == true) const Padding(padding: EdgeInsets.all(8),
            child: Text('This diff is too large to display in full.', style: TextStyle(fontSize: 12, color: opencodeMuted))),
          Expanded(child: DiffViewer(files: files, directory: repo.root ?? widget.controller.cwd,
            selectedPath: _path, revealRevision: _revision,
            onSelect: (path) => setState(() => _select(path)))),
        ]);
      })),
  ]);
}
