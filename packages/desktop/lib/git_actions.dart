// Commit controls and file selection follow T3 Code GitActionsControl.tsx, 86d8838e9.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'appearance.dart';
import 'file_icon.dart';
import 'git_actions_state.dart';
import 'details_row.dart';

class GitActionsControl extends StatefulWidget {
  const GitActionsControl({super.key, required this.controller, this.provider, this.model});
  final GitActionsController controller;
  final String? provider, model;
  @override
  State<GitActionsControl> createState() => _GitActionsControlState();
}

class _GitActionsControlState extends State<GitActionsControl> with WidgetsBindingObserver {
  Timer? _refresh;
  GitActionsController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshAfterBuild();
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) {
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused) unawaited(controller.refresh());
    });
  }
  @override
  void didUpdateWidget(GitActionsControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != controller) _refreshAfterBuild();
  }

  void _refreshAfterBuild() {
    final target = controller;
    // The checkout controller also notifies widgets outside this subtree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(controller, target)) unawaited(target.refresh());
    });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(controller.refresh(force: true));
  }
  @override
  void dispose() { _refresh?.cancel(); WidgetsBinding.instance.removeObserver(this); super.dispose(); }

  Future<void> _run(String action) async {
    if (controller.busy) return;
    if (action == 'push') {
      await controller.run(action);
      return;
    }
    await controller.refresh(force: true);
    if (!mounted || controller.busy) return;
    final repository = controller.state.repository;
    if (repository == null || repository.files.isEmpty) return;
    final result = await showDialog<({String message, List<String> paths})>(context: context,
      builder: (context) => _CommitDialog(repository: repository, action: action));
    if (result == null) return;
    await controller.run(action, message: result.message, filePaths: result.paths,
      provider: widget.provider, model: widget.model);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: controller, builder: (context, _) {
    final state = controller.state, repository = state.repository;
    if (repository?.isRepo != true) {
      if (state is GitFailed) {
        return DetailsRow(icon: const Icon(Icons.sync_problem_outlined), label: 'Retry Git status',
          tooltip: state.message, onPressed: () => unawaited(controller.refresh(force: true)));
      }
      return state is GitLoading ? const DetailsRow(icon: SizedBox.square(dimension: 14,
        child: CircularProgressIndicator(strokeWidth: 1.5)), label: 'Loading Git status…') : const SizedBox.shrink();
    }
    if (controller.busy) {
      if (state is GitRefreshing) {
        return const DetailsRow(icon: Padding(padding: EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 1.5, color: opencodeMuted)), label: 'Refreshing Git status…');
      }
      final operation = state is GitRunning ? state : (state as GitCancelling).operation;
      return DetailsRow(icon: const Padding(padding: EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 1.5, color: opencodeMuted)),
        label: state is GitCancelling ? 'Cancelling…' : operation.label,
        tooltip: operation.output ?? operation.label,
        trailing: IconButton(tooltip: 'Cancel Git action', style: detailsMenuStyle,
          onPressed: state is GitCancelling ? null : controller.cancel,
          icon: const Icon(Icons.close_rounded, size: 15, color: opencodeMuted)));
    }
    final repo = repository!;
    final canCommit = repo.files.isNotEmpty && !repo.files.any((file) => file.conflicted);
    final canPublish = repo.branch != null && repo.remote != null && repo.behind == 0;
    final canPush = canPublish && repo.head != null;
    final action = canCommit ? canPublish ? 'commit_push' : 'commit' : 'push';
    final enabled = canCommit || canPush && (repo.ahead > 0 || repo.upstream == null);
    final label = canCommit ? canPublish ? 'Commit & push' : 'Commit'
      : enabled ? 'Push' : repo.behind > 0 ? 'Behind upstream' : 'Up to date';
    final hint = state is GitCompleted ? state.message : state is GitCancelled
      ? '${state.commit == null ? '' : 'Committed ${state.commit!.sha.substring(0, 7)}. '}Git action cancelled. Status refreshed.'
      : repo.files.any((file) => file.conflicted) ? 'Resolve merge conflicts before committing'
      : '${repo.branch ?? 'Detached HEAD'} · ${repo.files.length} changed files'
        '${repo.ahead > 0 ? ' · ${repo.ahead} ahead' : ''}${repo.behind > 0 ? ' · ${repo.behind} behind' : ''}';
    return Column(mainAxisSize: MainAxisSize.min, children: [
      DetailsRow(label: label, tooltip: hint,
        icon: Icon(state is GitCompleted ? Icons.check_rounded : Icons.cloud_upload_outlined),
        onPressed: enabled ? () => unawaited(_run(action)) : null,
        trailing: PopupMenuButton<String>(tooltip: 'Git actions', padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 180),
            icon: detailsChevron, style: detailsMenuStyle,
            onSelected: (value) {
              if (value == 'refresh') { unawaited(controller.refresh(force: true)); }
              else { unawaited(_run(value)); }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'commit', enabled: canCommit, child: const Text('Commit…')),
              PopupMenuItem(value: 'commit_push', enabled: canCommit && canPublish, child: const Text('Commit & push…')),
              PopupMenuItem(value: 'push', enabled: canPush && (repo.ahead > 0 || repo.upstream == null), child: const Text('Push')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'refresh', child: Text('Refresh Git status')),
            ])),
      if (state is GitFailed) TextButton.icon(
        onPressed: () => unawaited(showDialog<void>(context: context, builder: (context) => AlertDialog(
          title: const Text('Git action failed'), content: SizedBox(width: 480, child: SelectableText(state.message)),
          actions: [TextButton(onPressed: () { controller.acknowledge(); Navigator.pop(context); }, child: const Text('Close'))]))),
        icon: const Icon(Icons.error_outline_rounded, size: 14, color: Color(0xffc23838)),
        label: const Text('Git action failed · View details', style: TextStyle(fontSize: 11, color: Color(0xffc23838)))),
    ]);
  });
}

class _CommitDialog extends StatefulWidget {
  const _CommitDialog({required this.repository, required this.action});
  final GitRepository repository;
  final String action;
  @override
  State<_CommitDialog> createState() => _CommitDialogState();
}

class _CommitDialogState extends State<_CommitDialog> {
  final _message = TextEditingController();
  late final _selected = widget.repository.files.map((file) => file.path).toSet();
  @override
  void dispose() { _message.dispose(); super.dispose(); }
  void _submit() {
    if (_selected.isNotEmpty) Navigator.pop(context, (message: _message.text.trim(), paths: _selected.toList()));
  }
  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: {const SingleActivator(LogicalKeyboardKey.enter, meta: true): const ActivateIntent(),
      const SingleActivator(LogicalKeyboardKey.enter, control: true): const ActivateIntent()},
    child: Actions(actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) { _submit(); return null; })},
      child: Dialog(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520, maxHeight: 620),
          child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(widget.action == 'commit_push' ? 'Commit & push changes' : 'Commit changes',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: opencodeInk)),
              const SizedBox(height: 6),
              const Text('Choose the files to include in this commit.', style: TextStyle(fontSize: 12, color: opencodeMuted)),
              const SizedBox(height: 18),
              Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: opencodeLayer,
                border: Border.all(color: opencodeBorder), borderRadius: BorderRadius.circular(8)),
                child: Row(children: [
                  const Icon(Icons.call_split_rounded, size: 15, color: opencodeMuted),
                  const SizedBox(width: 8),
                  Expanded(child: Text(widget.repository.branch ?? 'Detached HEAD',
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500))),
                  if (widget.repository.remote != null) Text(widget.repository.remote!,
                    style: const TextStyle(fontSize: 11, color: opencodeFaint)),
                ])),
              const SizedBox(height: 12),
              Row(children: [
                Checkbox(value: _selected.length == widget.repository.files.length ? true : _selected.isEmpty ? false : null,
                  tristate: true, visualDensity: VisualDensity.compact,
                  onChanged: (_) => setState(() {
                    if (_selected.length == widget.repository.files.length) { _selected.clear(); }
                    else { _selected.addAll(widget.repository.files.map((file) => file.path)); }
                  })),
                Expanded(child: Text('${_selected.length} of ${widget.repository.files.length} files selected',
                  style: const TextStyle(fontSize: 12, color: opencodeMuted))),
              ]),
              Flexible(child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(shrinkWrap: true, itemCount: widget.repository.files.length,
                  itemExtent: 32, itemBuilder: (context, index) {
                    final file = widget.repository.files[index];
                    return CheckboxListTile(value: _selected.contains(file.path), dense: true,
                      controlAffinity: ListTileControlAffinity.leading, contentPadding: EdgeInsets.zero,
                      onChanged: (selected) => setState(() {
                        if (selected == true) { _selected.add(file.path); } else { _selected.remove(file.path); }
                      }),
                      title: Tooltip(message: file.previousPath == null ? file.path : '${file.previousPath} → ${file.path}',
                        child: Row(children: [
                          FileIcon(file.path, size: 14), const SizedBox(width: 8),
                          Expanded(child: Text(file.path, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 11))),
                          const SizedBox(width: 8),
                          Text(file.status == '??' ? 'A' : file.status.trim(),
                            style: const TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 10, color: opencodeMuted)),
                        ])));
                  }))),
              const SizedBox(height: 18),
              const Text('Commit message (optional)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              TextField(controller: _message, autofocus: true, minLines: 3, maxLines: 5, maxLength: 10000,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(hintText: 'Leave empty to auto-generate', counterText: '',
                  contentPadding: EdgeInsets.all(12))),
              const SizedBox(height: 20),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(onPressed: _selected.isEmpty ? null : _submit,
                  child: Text(widget.action == 'commit_push' ? 'Commit & push' : 'Commit')),
              ]),
            ]))))));
}
