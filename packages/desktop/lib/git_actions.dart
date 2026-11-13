// Commit dialog follows Harness client/lib/ui/git_actions.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'desktop_menu.dart';
import 'git_action_glyphs.dart';
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
    final result = await showDialog<_CommitRequest>(context: context, barrierColor: const Color(0x22000000),
      builder: (context) => _CommitDialog(repository: repository, controller: controller, action: action));
    if (result == null) return;
    await controller.run(result.action, message: result.message, includeUnstaged: result.includeUnstaged,
      newBranch: result.newBranch, provider: widget.provider, model: widget.model);
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
          child: CircularProgressIndicator(strokeWidth: 1.5, color: desktopSecondary)), label: 'Refreshing Git status…');
      }
      final operation = state is GitRunning ? state : (state as GitCancelling).operation;
      return DetailsRow(icon: const Padding(padding: EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 1.5, color: desktopSecondary)),
        label: state is GitCancelling ? 'Cancelling…' : operation.label,
        tooltip: operation.output ?? operation.label,
        trailing: IconButton(tooltip: 'Cancel Git action', style: detailsMenuStyle,
          onPressed: state is GitCancelling ? null : controller.cancel,
          icon: const Icon(Icons.close_rounded, size: 15, color: desktopSecondary)));
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
        icon: const Icon(Icons.error_outline_rounded, size: 14, color: desktopError),
        label: const Text('Git action failed · View details', style: TextStyle(fontSize: 11, color: desktopError))),
    ]);
  });
}

typedef _CommitRequest = ({String action, String message, bool includeUnstaged, String? newBranch});

class _CommitDialog extends StatefulWidget {
  const _CommitDialog({required this.repository, required this.controller, required this.action});
  final GitRepository repository;
  final GitActionsController controller;
  final String action;
  @override
  State<_CommitDialog> createState() => _CommitDialogState();
}

class _CommitDialogState extends State<_CommitDialog> {
  late final _message = TextEditingController(text: widget.controller.commitMessage);
  final _branch = TextEditingController();
  final _messageFocus = FocusNode(), _branchFocus = FocusNode();
  final _branchMenu = MenuController();
  late bool _includeUnstaged = widget.controller.includeUnstaged;
  late String _selectedAction = widget.action;
  late Future<GitRepository> _selection = _loadSelection();
  CancellationToken? _read;
  bool _newBranch = false;
  String? _validation;

  Future<GitRepository> _loadSelection() {
    _read?.cancel();
    final token = _read = CancellationToken();
    return _includeUnstaged ? Future.value(widget.repository) : widget.controller.commitSelection(false, token);
  }

  void _chooseIncludeUnstaged(bool value) {
    widget.controller.chooseIncludeUnstaged(value);
    setState(() { _includeUnstaged = value; _selection = _loadSelection(); });
  }

  void _submit(String action) {
    if (widget.controller.busy) return;
    if (action != 'push' && _newBranch && _branch.text.trim().isEmpty) {
      setState(() => _validation = 'Enter a branch name.');
      _branchFocus.requestFocus();
      return;
    }
    Navigator.pop(context, (action: action, message: _message.text.trim(), includeUnstaged: _includeUnstaged,
      newBranch: action != 'push' && _newBranch ? _branch.text.trim() : null));
  }

  @override
  void dispose() {
    _read?.cancel();
    _message.dispose(); _branch.dispose(); _messageFocus.dispose(); _branchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<GitRepository>(key: ValueKey(_includeUnstaged),
    future: _selection, builder: (context, snapshot) {
      final repo = widget.repository, selection = snapshot.data;
      final loading = snapshot.connectionState != ConnectionState.done;
      final conflict = repo.files.any((file) => file.conflicted);
      final canCommit = !widget.controller.busy && !loading && selection != null && selection.files.isNotEmpty && !conflict;
      final canPublish = repo.branch != null && repo.remote != null && repo.behind == 0;
      final canPush = canPublish && repo.head != null && (repo.ahead > 0 || repo.upstream == null);
      final commitReason = loading ? 'Loading changes…' : snapshot.hasError ? 'Could not load changes'
        : conflict ? 'Resolve merge conflicts before committing' : 'No changes to commit';
      final pushReason = repo.remote == null ? 'No Git remote configured for push' : repo.branch == null
        ? 'Check out a branch before pushing' : repo.behind > 0 ? 'Pull or rebase upstream changes before pushing' : 'No new commits to push';
      final actions = [if (canCommit) 'commit', if (canCommit && canPublish) 'commit_push', if (canPush) 'push'];
      return Dialog(backgroundColor: desktopSurface, surfaceTintColor: Colors.transparent, elevation: 0,
        constraints: const BoxConstraints(minWidth: 0),
        insetPadding: EdgeInsets.symmetric(horizontal: MediaQuery.sizeOf(context).width * .04, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: DecoratedBox(decoration: BoxDecoration(color: desktopSurface, borderRadius: BorderRadius.circular(16),
          boxShadow: const [BoxShadow(color: Color(0x30000000), offset: Offset(0, 16), blurRadius: 32, spreadRadius: -8)]),
          child: Semantics(namesRoute: true, label: 'Commit or push', child: SizedBox(width: 420,
            child: Focus(skipTraversal: true, onKeyEvent: (_, event) {
              if (event is! KeyDownEvent || actions.isEmpty) return KeyEventResult.ignored;
              final key = event.logicalKey;
              if (key == LogicalKeyboardKey.enter && (HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed)) {
                _submit(actions.contains(_selectedAction) ? _selectedAction : actions.first);
                return KeyEventResult.handled;
              }
              if (!_messageFocus.hasFocus && !_branchFocus.hasFocus &&
                  (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp)) {
                final index = actions.indexOf(_selectedAction);
                setState(() => _selectedAction = actions[(index + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) % actions.length]);
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            }, child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(4),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                DesktopMenuAnchor(controller: _branchMenu,
                  style: MenuStyle(backgroundColor: const WidgetStatePropertyAll(desktopSidebar),
                    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
                    padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
                    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
                  menuChildren: [
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Text('Commit to', style: TextStyle(fontSize: 12))),
                    MenuItemButton(leadingIcon: _gitGlyph('branch', desktopSecondary),
                      trailingIcon: !_newBranch ? const Icon(Icons.check_rounded, size: 14) : null,
                      onPressed: () => setState(() { _newBranch = false; _validation = null; }),
                      child: Text(repo.branch ?? 'Detached HEAD')),
                    MenuItemButton(leadingIcon: const Icon(Icons.add_rounded, size: 16),
                      trailingIcon: _newBranch ? const Icon(Icons.check_rounded, size: 14) : null,
                      onPressed: () => setState(() { _newBranch = true; _validation = null; }), child: const Text('New branch')),
                  ], builder: (context, menu, focus) => SizedBox(height: 32, child: TextButton(focusNode: focus,
                    onPressed: () => menu.isOpen ? menu.close() : menu.open(),
                    style: TextButton.styleFrom(foregroundColor: desktopSecondary, minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap, padding: const EdgeInsets.symmetric(horizontal: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                    child: Row(children: [_gitGlyph('branch', desktopSecondary), const SizedBox(width: 8),
                      Expanded(child: Text(_newBranch ? 'New branch' : repo.branch ?? 'Detached HEAD',
                        overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, height: 1.5))),
                      const Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: desktopSecondary),
                    ])))),
                const SizedBox(height: 4),
                if (_newBranch) Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: TextField(controller: _branch, focusNode: _branchFocus, autofocus: true,
                    style: const TextStyle(fontSize: 14), onChanged: (_) { if (_validation != null) setState(() => _validation = null); },
                    decoration: const InputDecoration(hintText: 'Create a new branch', isDense: true))),
                SizedBox(height: 80, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Semantics(label: 'Commit message', child: TextField(controller: _message, focusNode: _messageFocus,
                    onChanged: widget.controller.editCommitMessage,
                    autofocus: !_newBranch, expands: true, minLines: null, maxLines: null, maxLength: 10000,
                    keyboardType: TextInputType.multiline, style: const TextStyle(fontSize: 14, height: 1.5),
                    decoration: const InputDecoration(hintText: 'Commit message (leave blank to generate)…',
                      hintStyle: TextStyle(color: desktopSecondary, fontWeight: FontWeight.w400),
                      border: InputBorder.none, contentPadding: EdgeInsets.zero, isDense: true, counterText: ''),
                  )))),
                Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 12), child: Row(children: [
                  SizedBox.square(dimension: 16, child: Checkbox(value: _includeUnstaged,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, visualDensity: VisualDensity.compact,
                    onChanged: (value) => _chooseIncludeUnstaged(value ?? true))),
                  const SizedBox(width: 8),
                  Expanded(child: GestureDetector(onTap: () => _chooseIncludeUnstaged(!_includeUnstaged),
                    child: const Text('Include unstaged changes', overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, height: 1.5, color: desktopForeground)))),
                  const SizedBox(width: 8),
                  if (loading) const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.2))
                  else if (selection != null) ...[
                    Text('+${selection.additions}', style: const TextStyle(fontSize: 12, color: Color(0xff00a240))),
                    const SizedBox(width: 4),
                    Text('-${selection.deletions}', style: const TextStyle(fontSize: 12, color: Color(0xffba2623))),
                  ],
                ])),
                if (_validation != null) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Text(_validation!, style: const TextStyle(fontSize: 12, color: desktopError))),
                if (snapshot.hasError) Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
                  const Expanded(child: Text('Could not load changes', style: TextStyle(fontSize: 12, color: desktopError))),
                  TextButton(onPressed: () => setState(() => _selection = _loadSelection()), child: const Text('Retry')),
                ])),
                const SizedBox(height: 4),
                const Divider(height: 1, thickness: 1, color: desktopBorder),
                Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(children: [
                  _GitCommandRow(label: 'Commit', glyph: 'commit', reason: commitReason, enabled: canCommit,
                    selected: _selectedAction == 'commit', onHighlight: () => setState(() => _selectedAction = 'commit'),
                    onSelect: () => _submit('commit')),
                  const SizedBox(height: 4),
                  _GitCommandRow(label: 'Commit and push', glyph: 'push', reason: canCommit ? pushReason : commitReason,
                    enabled: canCommit && canPublish, selected: _selectedAction == 'commit_push',
                    onHighlight: () => setState(() => _selectedAction = 'commit_push'), onSelect: () => _submit('commit_push')),
                  const SizedBox(height: 4),
                  _GitCommandRow(label: 'Push', glyph: 'push', reason: pushReason, enabled: canPush,
                    selected: _selectedAction == 'push', onHighlight: () => setState(() => _selectedAction = 'push'),
                    onSelect: () => _submit('push')),
                ])),
              ]))))))));
    });
}

Widget _gitGlyph(String name, Color color) => SvgPicture.string(gitActionGlyphs[name]!, width: 16, height: 16,
  colorFilter: ColorFilter.mode(color, BlendMode.srcIn));

class _GitCommandRow extends StatelessWidget {
  const _GitCommandRow({required this.label, required this.glyph, required this.reason, required this.enabled,
    required this.onSelect, required this.onHighlight, required this.selected});
  final String label, glyph, reason;
  final bool enabled, selected;
  final VoidCallback onSelect, onHighlight;
  @override
  Widget build(BuildContext context) {
    final active = enabled && selected;
    return Tooltip(message: enabled ? '' : reason, child: SizedBox(height: 32,
      child: TextButton(onPressed: enabled ? onSelect : null,
        onHover: (value) { if (value) onHighlight(); }, onFocusChange: (value) { if (value) onHighlight(); },
        style: TextButton.styleFrom(alignment: Alignment.centerLeft, foregroundColor: desktopForeground,
          disabledForegroundColor: desktopForeground, backgroundColor: active ? desktopHover : Colors.transparent,
          minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        child: Opacity(opacity: !enabled ? .25 : active ? 1 : .75, child: Row(children: [
          _gitGlyph(glyph, desktopForeground), const SizedBox(width: 8),
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, height: 1.5))),
          if (active) Text(Theme.of(context).platform == TargetPlatform.macOS ? '⌘↵' : 'Ctrl+↵',
            style: const TextStyle(fontSize: 12, color: desktopSecondary)),
        ])))));
  }
}
