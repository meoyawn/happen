import 'dart:async';

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'checkout_pull.dart';
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
    : project = source.project!, draft = source.currentDraft {
    _state = _snapshot();
    machines.addListener(_machinesChanged);
  }
  final MachinesController machines;
  final DesktopSession source;
  final Project project;
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
    return _selection = _choose(checkout);
  }

  Future<bool> _choose(ThreadCheckout checkout) async {
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
      if (!_current || inspected['available'] != true || inspected['repository'] != previous.repository) {
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
  const ThreadMachinePicker({super.key, required this.machines, required this.session});
  final MachinesController machines;
  final DesktopSession session;
  @override
  State<ThreadMachinePicker> createState() => _ThreadMachinePickerState();
}

class _ThreadMachinePickerState extends State<ThreadMachinePicker> {
  final _machineMenu = MenuController(), _workspaceMenu = MenuController();
  ThreadMachineController? _controller;
  MachineSession? _pendingMachine;
  DesktopSession? _source;
  Project? _project;
  String? _draftId;
  @override
  void initState() { super.initState(); _bind(); }
  @override
  void didUpdateWidget(ThreadMachinePicker oldWidget) { super.didUpdateWidget(oldWidget); _bind(); }
  void _bind() {
    final session = widget.session;
    final id = session.task == null ? session.currentDraft.id : null;
    if (identical(_source, session) && identical(_project, session.project) && _draftId == id) return;
    _controller?.removeListener(_changed);
    if (_controller != null) unawaited(_controller!.close());
    _source = session; _project = session.project; _draftId = id; _pendingMachine = null;
    _controller = session.project == null ? null : ThreadMachineController(widget.machines, session);
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

  Widget _control(Widget icon, String label, VoidCallback? onPressed, String tooltip) => Tooltip(
    message: tooltip,
    child: TextButton(onPressed: onPressed, style: TextButton.styleFrom(foregroundColor: desktopSecondary,
      minimumSize: const Size(0, 24), tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      textStyle: const TextStyle(fontFamily: desktopFontFamily, fontSize: 12, fontWeight: FontWeight.w400),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [icon, const SizedBox(width: 6),
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
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

  @override
  Widget build(BuildContext context) {
    final machine = widget.machines.machineFor(widget.session), state = _controller?.state;
    final ready = switch (state) { ThreadMachineReady() => state, ThreadMachineSelecting(:final previous) => previous, _ => null };
    final checkouts = ready?.checkouts ?? const <ThreadCheckout>[];
    final targetMachine = _pendingMachine ?? machine;
    final workspaceChoices = checkouts.where((choice) => identical(choice.machine.session, targetMachine.session)).toList();
    final selected = checkouts.where((choice) => identical(choice.machine.session, widget.session) && choice.path == _project?.path).firstOrNull;
    final busy = state is ThreadMachineSelecting || widget.session.submitting || widget.session.pullingCheckout;
    final machines = widget.machines.sessions;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: MenuAnchor(controller: _machineMenu, style: _menuStyle,
        menuChildren: [_heading('Run on'),
          for (final target in machines) MenuItemButton(
            leadingIcon: MachineGlyph(widget.machines.iconFor(target.alias)),
            trailingIcon: target.alias == machine.alias ? const Icon(Icons.check, size: 14) : null,
            onPressed: busy || !target.session.connected || !checkouts.any((choice) => identical(choice.machine.session, target.session)) ? null : () {
              final options = checkouts.where((choice) => identical(choice.machine.session, target.session)).toList();
              if (options.length == 1) { unawaited(_choose(options.single)); return; }
              setState(() => _pendingMachine = target);
              _machineMenu.close();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && identical(_pendingMachine?.session, target.session)) _workspaceMenu.open();
              });
            }, child: Text(target.name)),
          if (ready != null) ...[
            for (final entry in ready.errors.entries) MenuItemButton(onPressed: null,
              child: Tooltip(message: entry.value, child: Text('${entry.key} · Unavailable'))),
            if (ready.repository == null) const MenuItemButton(onPressed: null, child: Text('No Git remote to match')),
            if (ready.truncated) const MenuItemButton(onPressed: null, child: Text('Some locations were not checked')),
          ], ..._status(state)],
        builder: (_, controller, _) => _control(MachineGlyph(widget.machines.iconFor(machine.alias), size: 13),
          machine.name, _controller == null || busy ? null : () => controller.isOpen ? controller.close() : controller.open(), 'Run on'))),
      const SizedBox(width: 2),
      Flexible(child: MenuAnchor(controller: _workspaceMenu, style: _menuStyle,
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
              ])))), ..._status(state)],
        builder: (_, controller, _) => _control(Icon(selected?.worktree == true ? Icons.account_tree_outlined : Icons.folder_outlined, size: 13),
          selected?.worktree == true ? 'Worktree' : 'Current checkout', _controller == null || busy ? null
            : () => controller.isOpen ? controller.close() : controller.open(), 'Workspace'))),
      const SizedBox(width: 2),
      Flexible(child: CheckoutPullControl(session: widget.session,
        enabled: state is! ThreadMachineSelecting && !widget.session.submitting)),
    ]);
  }
}
