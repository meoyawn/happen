import 'dart:async';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'diff_viewer.dart';
import 'file_change.dart';
import 'git_actions_state.dart';

sealed class _ReviewState {
  const _ReviewState(this.repository);
  final GitRepository? repository;
}
final class _ReviewLoading extends _ReviewState { const _ReviewLoading(super.repository); }
final class _ReviewReady extends _ReviewState { const _ReviewReady(GitRepository super.repository); }
final class _ReviewFailed extends _ReviewState {
  const _ReviewFailed(super.repository, this.message);
  final String message;
}

_ReviewState _transition(_ReviewState current, _ReviewState next) => switch ((current, next)) {
  (_ReviewLoading() || _ReviewReady() || _ReviewFailed(), _ReviewLoading()) => next,
  (_ReviewLoading(), _ReviewReady() || _ReviewFailed()) => next,
  _ => throw StateError('Invalid checkout review transition'),
};

/// Captures the checkout controller. Comparison reads never mutate the shared
/// status used by commit/push, and hidden panels retain their rendered patches.
class WorkspaceChanges extends StatefulWidget {
  const WorkspaceChanges({super.key, required this.controller, this.active = true});
  final GitActionsController controller;
  final bool active;
  @override
  State<WorkspaceChanges> createState() => _WorkspaceChangesState();
}

class _WorkspaceChangesState extends State<WorkspaceChanges> {
  final _lifetime = CancellationToken();
  CancellationToken? _read;
  String? _path;
  int _revision = 0;
  String _comparison = 'uncommitted';
  late _ReviewState _state = _ReviewLoading(widget.controller.state.repository);
  late List<ChangedFile> _files = const [];
  GitRepository? _observed;
  bool _listening = false;

  @override
  void initState() {
    super.initState(); _watch();
    if (widget.active) unawaited(_refresh());
  }

  void _watch() {
    if (_listening) return;
    _listening = true; _observed = widget.controller.state.repository;
    widget.controller.addListener(_changed);
  }

  void _changed() {
    final repository = widget.controller.state.repository;
    if (identical(_observed, repository)) return;
    _observed = repository;
    if (widget.active) unawaited(_refresh());
  }

  @override
  void didUpdateWidget(WorkspaceChanges oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed); _listening = false; _watch();
      _files = const []; _state = const _ReviewLoading(null);
    }
    if (!widget.active) { _read?.cancel(); _read = null; }
    else if (!oldWidget.active || oldWidget.controller != widget.controller) { unawaited(_refresh()); }
  }

  @override
  void reassemble() {
    super.reassemble();
    // Subscribe an existing mounted checkout panel without replacing its route.
    _read?.cancel(); _read = null; _watch();
    if (widget.active) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    _read?.cancel();
    final token = _read = CancellationToken(), comparison = _comparison;
    setState(() => _state = _transition(_state, _ReviewLoading(_state.repository)));
    try {
      final repository = await widget.controller.review(comparison, token.merge(_lifetime));
      token.throwIfCancelled();
      if (!mounted || !identical(_read, token) || comparison != _comparison) return;
      setState(() {
        _state = _transition(_state, _ReviewReady(repository));
        _files = List.unmodifiable([for (final file in repository.files) (
          path: file.path, oldPath: file.previousPath,
          kind: file.previousPath != null ? 'rename' : file.status == '??' ||
            (comparison == 'staged' ? file.status[0] : comparison == 'unstaged' ? file.status[1] : file.status).contains('A') ? 'add' :
            (comparison == 'staged' ? file.status[0] : comparison == 'unstaged' ? file.status[1] : file.status).contains('D') ? 'delete' : 'update',
          diff: '', additions: file.additions, deletions: file.deletions,
        )]);
        _revision++;
      });
    } on CancelledException {
      // Route visibility, comparison changes and disposal supersede this read.
    } catch (error) {
      if (mounted && identical(_read, token)) {
        setState(() => _state = _transition(_state, _ReviewFailed(_state.repository, '$error')));
      }
    } finally {
      if (identical(_read, token)) _read = null;
      token.cancel();
    }
  }

  void _compare(String? comparison) {
    if (comparison == null || comparison == _comparison) return;
    setState(() { _comparison = comparison; _files = const []; _state = const _ReviewLoading(null); _revision++; });
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _lifetime.cancel(); _read?.cancel();
    if (_listening) widget.controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repository = _state.repository;
    return DiffViewer(key: ValueKey(widget.controller), files: _files,
      directory: repository?.root ?? widget.controller.cwd, selectedPath: _path,
      revision: _revision, active: widget.active, loading: _state is _ReviewLoading,
      error: _state is _ReviewFailed ? (_state as _ReviewFailed).message : null,
      emptyLabel: repository?.isRepo == false ? 'This folder is not a Git repository' : switch (_comparison) {
        'staged' => 'No staged changes', 'unstaged' => 'No unstaged changes', _ => 'Working tree is clean',
      },
      onSelect: (path) => _path = path, onRefresh: _refresh,
      loadPatch: (path, hideWhitespace, cancellation) => widget.controller.diff(path, cancellation,
        comparison: _comparison, hideWhitespace: hideWhitespace, expectedHead: repository?.head),
      comparison: DropdownButtonHideUnderline(child: DropdownButton<String>(value: _comparison, isDense: true,
        borderRadius: BorderRadius.circular(8), iconSize: 16,
        style: const TextStyle(fontSize: 12, color: desktopForeground),
        items: const [DropdownMenuItem(value: 'uncommitted', child: Text('Uncommitted')),
          DropdownMenuItem(value: 'staged', child: Text('Staged')), DropdownMenuItem(value: 'unstaged', child: Text('Unstaged'))],
        onChanged: _compare)));
  }
}
