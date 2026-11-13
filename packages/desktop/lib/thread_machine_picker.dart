import 'dart:async';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

import 'add_project_dialog.dart';
import 'add_project_state.dart';
import 'appearance.dart';
import 'checkout_pull.dart';
import 'desktop_menu.dart';
import 'machines.dart';
import 'machine_icons.dart';
import 'session.dart';

sealed class ThreadMachineState { const ThreadMachineState(); }
final class ThreadMachineReady extends ThreadMachineState {
  ThreadMachineReady(this.repository, List<ThreadCheckout> checkouts, Map<String, String> errors, this.truncated)
    : checkouts = List.unmodifiable(checkouts), errors = Map.unmodifiable(errors);
  final String? repository;
  final List<ThreadCheckout> checkouts;
  final Map<String, String> errors;
  final bool truncated;
}
final class ThreadMachineSelecting extends ThreadMachineState {
  const ThreadMachineSelecting(this.previous, this.checkout);
  final ThreadMachineReady previous;
  final ThreadCheckout checkout;
}
final class ThreadMachineFailed extends ThreadMachineState {
  const ThreadMachineFailed(this.error);
  final Object error;
}
final class ThreadMachineClosed extends ThreadMachineState { const ThreadMachineClosed(); }

ThreadMachineState _transition(ThreadMachineState current, ThreadMachineState next) => switch ((current, next)) {
  (ThreadMachineReady() || ThreadMachineFailed(), ThreadMachineReady()) => next,
  (ThreadMachineReady(), ThreadMachineSelecting()) => next,
  (ThreadMachineSelecting(), ThreadMachineReady() || ThreadMachineFailed()) => next,
  (_, ThreadMachineClosed()) when current is! ThreadMachineClosed => next,
  _ => throw StateError('Invalid thread machine transition'),
};

/// An unsent draft reads the application-owned machine catalog synchronously.
class ThreadMachineController extends ChangeNotifier {
  ThreadMachineController(this.machines, this.source)
    : project = source.project, draft = source.currentDraft {
    _state = _snapshot();
    machines.addListener(_machinesChanged);
  }
  final MachinesController machines;
  final DesktopSession source;
  final Project? project;
  final SessionDraft draft;
  final _lifetime = CancellationToken();
  CancellationToken? _operation;
  late ThreadMachineState _state;
  ThreadMachineState get state => _state;
  Future<bool>? _selection;
  Future<void>? _closing;
  bool get _current => identical(machines.active, source) && source.task == null && !source.submitting && draft.submission == null &&
    source.sessionDrafts.contains(draft) && identical(source.project, project) && source.currentDraft.id == draft.id;

  ThreadMachineReady _snapshot() {
    final project = this.project;
    if (project == null) return ThreadMachineReady(null, const [], const {}, false);
    final catalog = machines.workspaceCatalog(source, project);
    return ThreadMachineReady(catalog.repository, catalog.checkouts, catalog.errors, catalog.truncated);
  }

  void _machinesChanged() {
    if (_lifetime.isCancelled || !_current || _state is ThreadMachineSelecting) return;
    _set(_snapshot());
  }

  void _set(ThreadMachineState next) {
    _state = _transition(_state, next);
    notifyListeners();
  }

  Future<bool> choose(ThreadCheckout checkout) {
    if (_state is! ThreadMachineReady || !_current || source.pullingCheckout) return Future.value(false);
    return _selection = _choose(checkout, (_state as ThreadMachineReady).repository);
  }

  Future<bool> chooseProject(ProjectCheckout checkout) {
    if (_state is! ThreadMachineReady || !_current || source.pullingCheckout ||
        checkout.project.removing || !checkout.project.available) { return Future.value(false); }
    return _selection = _choose((machine: machines.machineFor(checkout.source), path: checkout.project.path,
      branch: checkout.project.branch, worktree: checkout.project.workspace?['worktree'] == true), projectRepository(checkout.project));
  }

  Future<bool> _choose(ThreadCheckout checkout, String? repository) async {
    if (_state is! ThreadMachineReady || !_current || source.pullingCheckout) return false;
    final previous = _state as ThreadMachineReady;
    final navigation = source.navigationRevision;
    final token = _operation = CancellationToken();
    final cancellation = token.merge(_lifetime);
    _set(ThreadMachineSelecting(previous, checkout));
    SessionDraft? prepared;
    try {
      final target = checkout.machine.session;
      final inspected = await target.client.inspectWorkspace(checkout.path, cancellation: cancellation);
      cancellation.throwIfCancelled();
      if (!_current || inspected['available'] != true || inspected['repository'] != repository) {
        throw StateError('The checkout changed. Refresh the machine list.');
      }
      final destination = await target.ensureProject(checkout.path, cancellation: cancellation);
      cancellation.throwIfCancelled();
      if (!_current) return false;
      prepared = await target.receiveDraft(source, draft, destination, cancellation: cancellation);
      if (cancellation.isCancelled || !_current) {
        if (!identical(target, source)) await target.removeRoutedDraft(prepared);
        if (!cancellation.isCancelled) _set(_snapshot());
        return false;
      }
      if (!identical(target, source)) {
        try { await source.removeRoutedDraft(draft); }
        catch (_) { await target.removeRoutedDraft(prepared); rethrow; }
      }
      if (cancellation.isCancelled || source.navigationRevision != navigation || !identical(machines.active, source)) return false;
      _set(_snapshot());
      machines.openDraftOn(checkout.machine, prepared);
      return true;
    } on CancelledException { return false; }
    catch (error) { if (!cancellation.isCancelled) _set(ThreadMachineFailed(error)); return false; }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    machines.removeListener(_machinesChanged);
    _lifetime.cancel();
    _operation?.cancel();
    await _selection;
    _set(const ThreadMachineClosed());
    dispose();
  }
}

class ThreadMachinePicker extends StatefulWidget {
  const ThreadMachinePicker({super.key, required this.machines, required this.session, this.machineMenuController});
  final MachinesController? machines;
  final DesktopSession session;
  final MenuController? machineMenuController;
  @override
  State<ThreadMachinePicker> createState() => _ThreadMachinePickerState();
}

class _ThreadMachinePickerState extends State<ThreadMachinePicker> {
  late final _fallbackMachineMenu = MenuController();
  MenuController get _machineMenu => widget.machineMenuController ?? _fallbackMachineMenu;
  final _workspaceMenu = MenuController();
  ThreadMachineController? _controller;
  MachineSession? _pendingMachine;
  MachinesController? _machines;
  DesktopSession? _source;
  Project? _project;
  String? _draftId;
  bool _cloning = false;
  @override
  void initState() { super.initState(); _bind(); }
  @override
  void didUpdateWidget(ThreadMachinePicker oldWidget) { super.didUpdateWidget(oldWidget); _bind(); }
  void _bind() {
    final session = widget.session, machines = widget.machines;
    final id = session.task == null ? session.currentDraft.id : null;
    if (identical(_machines, machines) && identical(_source, session) && identical(_project, session.project) && _draftId == id) return;
    _controller?.removeListener(_changed);
    if (_controller != null) unawaited(_controller!.close());
    _machines = machines; _source = session; _project = session.project; _draftId = id; _pendingMachine = null;
    _controller = session.project == null || machines == null ? null : ThreadMachineController(machines, session);
    _controller?.addListener(_changed);
  }
  void _changed() { if (mounted) setState(() {}); }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    if (_controller != null) unawaited(_controller!.close());
    super.dispose();
  }

  Future<void> _choose(ThreadCheckout checkout) async {
    _machineMenu.close(); _workspaceMenu.close();
    final controller = _controller;
    if (controller == null) return;
    final changed = await controller.choose(checkout);
    if (!changed && mounted && controller.state is ThreadMachineFailed) {
      widget.session.showError((controller.state as ThreadMachineFailed).error, title: 'Could not change machine');
    }
  }

  Future<void> _clone(MachineSession machine) async {
    final controller = _controller, project = _project;
    final repository = project == null ? null : projectRepository(project);
    if (_cloning || controller == null || controller.state is! ThreadMachineReady || project == null ||
        repository == null || !machine.session.connected) return;
    _machineMenu.close(); _workspaceMenu.close();
    setState(() => _cloning = true);
    try {
      final result = await showDialog<ProjectSaved>(context: context, barrierColor: const Color(0x22000000),
        builder: (_) => AddProjectDialog(session: widget.session, machines: widget.machines,
          location: ProjectLocation(machine, ProjectSource.git,
            remoteUrl: project.workspace?['remoteUrl'] as String? ?? repository,
            subdirectory: project.workspace?['subdirectory'] as String? ?? '')));
      if (result == null || !mounted || !identical(_controller, controller)) return;
      final changed = await controller.chooseProject((source: result.machine.session, project: result.project));
      if (controller.state case ThreadMachineFailed(:final error) when !changed && mounted) {
        widget.session.showError(error, title: 'Could not change machine');
      }
    } finally {
      if (mounted) setState(() => _cloning = false);
    }
  }

  Widget get _progress => const SizedBox(width: 12, height: 12,
    child: CircularProgressIndicator(strokeWidth: 1.5, color: desktopSecondary));

  Widget _control(Widget icon, String label, VoidCallback? onPressed, String tooltip, {required FocusNode focusNode, bool loading = false}) => Tooltip(
    message: tooltip,
    child: TextButton(focusNode: focusNode, onPressed: onPressed, style: TextButton.styleFrom(foregroundColor: desktopSecondary,
      minimumSize: const Size(0, 24), tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      textStyle: const TextStyle(fontFamily: desktopFontFamily, fontSize: 12, fontWeight: FontWeight.w400),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [icon, const SizedBox(width: 6),
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (loading) ...[const SizedBox(width: 6), _progress],
        const SizedBox(width: 3), const Icon(Icons.expand_more, size: 12)])),
  );

  MenuStyle get _menuStyle => MenuStyle(alignment: Alignment.bottomLeft,
    backgroundColor: const WidgetStatePropertyAll(Colors.white),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    padding: const WidgetStatePropertyAll(EdgeInsets.all(4)),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(8),
      side: const BorderSide(color: desktopBorder))));

  Widget _heading(String label) => Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 5),
    child: Text(label, style: const TextStyle(fontSize: 11, color: desktopTertiary)));

  List<Widget> _status(ThreadMachineState? state) => [
    if (state case ThreadMachineFailed(:final error))
      MenuItemButton(onPressed: null, child: SizedBox(width: 300, child: Text('$error', maxLines: 3))),
  ];

  ({String? label, String? error, bool loading}) _machineStatus(String? alias, DesktopSession? session) {
    final machines = widget.machines;
    if (machines == null) return (label: 'Loading machines…', error: null, loading: true);
    final state = alias == null ? null : machines.state(alias);
    if (state is MachineFailed) return (label: 'Connection failed', error: '${state.error}', loading: false);
    if (state is MachineClosed) return (label: 'Disconnected', error: null, loading: false);
    if (session == null || state is MachineConnecting || !session.connected) {
      return (label: session == null ? 'Connecting…' : 'Reconnecting…', error: null, loading: true);
    }
    if (machines.discoveringWorkspaces(session)) return (label: 'Finding workspaces…', error: null, loading: true);
    return (label: null, error: null, loading: false);
  }

  Widget _machineItem(String? alias, String name, DesktopSession? session, ThreadMachineReady? ready, bool busy, String? selected) {
    final status = _machineStatus(alias, session);
    final options = ready?.checkouts.where((choice) => identical(choice.machine.session, session)).toList() ?? const <ThreadCheckout>[];
    final error = status.error ?? ready?.errors[name];
    final clone = options.isEmpty && ready?.repository != null && status.label == null && error == null && session?.connected == true;
    final label = status.label ?? (error != null ? 'Unavailable' : clone ? 'No matching workspace · Clone…' : null);
    final item = MenuItemButton(
      leadingIcon: MachineGlyph(widget.machines?.iconFor(alias) ?? parseMachineIcon(null, remote: alias != null)),
      trailingIcon: Row(mainAxisSize: MainAxisSize.min, children: [
        if (status.loading) _progress
        else if (error != null) const Icon(Icons.error_outline, size: 14),
        if (clone) const Icon(Icons.download_outlined, size: 14),
        if (alias == selected) ...[if (status.loading || error != null) const SizedBox(width: 8), const Icon(Icons.check, size: 14)],
      ]),
      onPressed: busy || session?.connected != true || options.isEmpty && !clone ? null : () {
        if (clone) { unawaited(_clone(widget.machines!.machineFor(session!))); return; }
        if (options.length == 1) { unawaited(_choose(options.single)); return; }
        final target = options.first.machine;
        setState(() => _pendingMachine = target);
        _machineMenu.close();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && identical(_pendingMachine?.session, target.session)) _workspaceMenu.open();
        });
      },
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 300),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (label != null) Text(label, style: const TextStyle(fontSize: 11, color: desktopTertiary)),
        ])),
    );
    return error == null ? item : Tooltip(message: error, child: item);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.machines ?? widget.session,
    builder: (context, _) => _picker(context));

  Widget _picker(BuildContext context) {
    final owner = widget.machines;
    final machine = owner?.machineFor(widget.session) ??
      (alias: widget.session.machineAlias, name: machineLabel(widget.session), session: widget.session);
    final state = _controller?.state;
    final ready = switch (state) { ThreadMachineReady() => state, ThreadMachineSelecting(:final previous) => previous, _ => null };
    final checkouts = ready?.checkouts ?? const <ThreadCheckout>[];
    final targetMachine = _pendingMachine ?? machine;
    final workspaceChoices = checkouts.where((choice) => identical(choice.machine.session, targetMachine.session)).toList();
    final selected = checkouts.where((choice) => identical(choice.machine.session, widget.session) && choice.path == _project?.path).firstOrNull;
    final busy = _cloning || state is ThreadMachineSelecting || widget.session.submitting || widget.session.pullingCheckout;
    final sessions = owner?.sessions ?? const <MachineSession>[];
    final machines = <({String? alias, String name, DesktopSession? session})>[
      if (owner == null) machine else (alias: null, name: 'local', session: owner.local),
      for (final host in owner?.hosts ?? const <RemoteMachine>[])
        (alias: host.alias, name: host.name, session: sessions.where((machine) => machine.alias == host.alias).firstOrNull?.session),
    ];
    final loading = machines.any((machine) => _machineStatus(machine.alias, machine.session).loading);
    final workspaceStatus = _machineStatus(targetMachine.alias, targetMachine.session);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: DesktopMenuAnchor(controller: _machineMenu, style: _menuStyle,
        menuChildren: [_heading('Run on'),
          for (final target in machines) _machineItem(target.alias, target.name, target.session, ready, busy, machine.alias),
          if (ready != null) ...[
            if (ready.repository == null) const MenuItemButton(onPressed: null, child: Text('No Git remote to match')),
            if (ready.truncated) const MenuItemButton(onPressed: null, child: Text('Some locations were not checked')),
          ], ..._status(state)],
        builder: (_, controller, focus) => _control(MachineGlyph(owner?.iconFor(machine.alias) ??
          parseMachineIcon(null, remote: machine.alias != null), size: 13),
          machine.name, busy ? null : () => controller.isOpen ? controller.close() : controller.open(), 'Run on',
          focusNode: focus, loading: loading || state is ThreadMachineSelecting))),
      const SizedBox(width: 2),
      Flexible(child: DesktopMenuAnchor(controller: _workspaceMenu, style: _menuStyle,
        onClose: () { if (mounted && _pendingMachine != null) setState(() => _pendingMachine = null); },
        menuChildren: [_heading(_pendingMachine == null ? 'Workspace' : 'Workspace · ${targetMachine.name}'),
          for (final checkout in workspaceChoices) MenuItemButton(
            leadingIcon: Icon(checkout.worktree ? Icons.account_tree_outlined : Icons.folder_outlined, size: 14),
            trailingIcon: identical(checkout.machine.session, widget.session) && checkout.path == _project?.path
              ? const Icon(Icons.check, size: 14) : null,
            onPressed: busy ? null : () => unawaited(_choose(checkout)),
            child: SizedBox(width: 300, child: Padding(padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${checkout.worktree ? 'Worktree' : 'Current checkout'} · ${checkout.branch ?? 'Detached HEAD'}',
                  style: const TextStyle(fontSize: 12)),
                Text(checkout.path, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: desktopTertiary)),
              ])))),
          if (workspaceStatus.loading) MenuItemButton(onPressed: null, leadingIcon: _progress, child: Text(workspaceStatus.label!)),
          ..._status(state)],
        builder: (_, controller, focus) => _control(Icon(selected?.worktree == true ? Icons.account_tree_outlined : Icons.folder_outlined, size: 13),
          selected?.worktree == true ? 'Worktree' : 'Current checkout', _controller == null || busy ? null
            : () => controller.isOpen ? controller.close() : controller.open(), 'Workspace', focusNode: focus, loading: workspaceStatus.loading))),
      const SizedBox(width: 2),
      Flexible(child: CheckoutPullControl(session: widget.session,
        enabled: state is! ThreadMachineSelecting && !widget.session.submitting)),
    ]);
  }
}
