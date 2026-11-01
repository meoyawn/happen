import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_file_picker/macos_file_picker.dart';
import 'package:protocol/protocol.dart';
import 'package:desktop_drop/desktop_drop.dart';

import 'conversation.dart';
import 'conversation_data.dart';
import 'appearance.dart';
import 'composer_dictation.dart';
import 'composer_attachments.dart';
import 'composer_editor.dart';
import 'composer_text_controller.dart';
import 'context_usage.dart';
import 'panel_state.dart';
import 'session_panels.dart';
import 'dictation.dart';
import 'dictation_controls.dart';
import 'file_autocomplete.dart';
import 'model_picker.dart';
import 'mcp_conversation.dart';
import 'session.dart';
import 'sidebar_frame.dart';
import 'sidebar_resizer.dart';
import 'interface_mode.dart';
import 'opencode_navigation.dart';
import 'window_chrome.dart';
import 'terminal.dart';

class DesktopView extends StatefulWidget {
  const DesktopView({super.key, required this.session});
  final DesktopSession session;

  @override
  State<DesktopView> createState() => _DesktopViewState();
}

class _DesktopViewState extends State<DesktopView> {
  static const _desktop = MethodChannel('happen/desktop');
  DesktopSession get session => widget.session;
  bool _picking = false, _settingsOpen = false;
  bool _homeOpen = false;
  final _windowChrome = ValueNotifier((fullscreen: false, trafficLightsEnd: 85.0));
  String? _nativeLayout;
  final _sessionSearchFocus = FocusNode();
  double? _dragSidebarWidth;
  final _composer = GlobalKey<_ComposerState>();
  final _conversationPaneKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _bindNavigation();
    session.addListener(_syncWindowChrome);
    _desktop.setMethodCallHandler((call) async {
      if (call.method == 'showSettings') await _settings();
      if (call.method == 'windowChromeChanged') _applyWindowChrome(call.arguments);
    });
    _syncWindowChrome();
  }

  Listenable get _viewChanges => Listenable.merge([session, _windowChrome]);
  double get _trafficInset => defaultTargetPlatform == TargetPlatform.macOS && !_windowChrome.value.fullscreen ? _windowChrome.value.trafficLightsEnd + 16 : 0;

  void _applyWindowChrome(Object? value) {
    if (!mounted || value is! Map) return;
    final end = value['trafficLightsEnd'];
    _windowChrome.value = (fullscreen: value['fullscreen'] == true,
      trafficLightsEnd: end is num ? end.toDouble() : _windowChrome.value.trafficLightsEnd);
  }

  void _syncWindowChrome() {
    if (defaultTargetPlatform != TargetPlatform.macOS) return;
    final layout = _hasSidebar ? 'side' : 'top';
    if (layout == _nativeLayout) return;
    _nativeLayout = layout;
    unawaited(_run(() async {
      final result = await _desktop.invokeMethod<Object?>('setWindowLayout', {'layout': layout});
      _applyWindowChrome(result);
    }));
  }

  @override
  void didUpdateWidget(DesktopView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == session) return;
    oldWidget.session.removeListener(_syncWindowChrome);
    session.addListener(_syncWindowChrome);
    _syncWindowChrome();
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_navigateKey);
    session.removeListener(_syncWindowChrome);
    _desktop.setMethodCallHandler(null);
    _sessionSearchFocus.dispose();
    _windowChrome.dispose();
    super.dispose();
  }

  Future<void> _settings() async {
    if (_settingsOpen || !mounted) return;
    _settingsOpen = true;
    try {
      await session.dictation.cancel();
      if (!mounted) return;
      await Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (context) => ListenableBuilder(
          listenable: _viewChanges,
          builder: (context, _) => Scaffold(
            appBar: AppBar(automaticallyImplyLeading: false, titleSpacing: 0,
              toolbarHeight: _hasSidebar ? 64 : 44,
              title: DesktopWindowDragRegion(child: Row(children: [
                SizedBox(width: _trafficInset == 0 ? 8 : _trafficInset),
                const BackButton(), const SizedBox(width: 8), const Text('Settings'),
              ]))),
            body: Align(alignment: Alignment.topCenter, child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(32, 20, 32, 40),
              child: SizedBox(
              width: 640,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (session.loginSucceeded) ...[
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(color: const Color(0xffe3f1e8), borderRadius: BorderRadius.circular(12)),
                      child: Row(children: [
                        const Icon(Icons.check_circle, color: Color(0xff296748)),
                        const SizedBox(width: 12),
                        Expanded(child: Text('Signed in to ${session.loginProvider == 'openai' ? 'ChatGPT' : 'OpenCode'}. Your account is connected.')),
                      ]),
                    ),
                    const SizedBox(height: 20),
                  ],
                  OpenCodeInterfacePicker(selected: session.openCodeLayout,
                    onSelected: (layout) => unawaited(_run(() => session.chooseOpenCodeLayout(layout)))),
                  const Padding(padding: EdgeInsets.symmetric(vertical: 28), child: Divider(height: 1)),
                  const Text('Accounts', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  for (final provider in session.providers) _accountCard(provider),
                  const SizedBox(height: 24),
                  const Text('Messages sent while a task is working', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'steer', label: Text('Steer')),
                      ButtonSegment(value: 'queue', label: Text('Queue')),
                    ],
                    selected: {session.deliveryMode},
                    onSelectionChanged: (value) => _run(() => session.chooseDeliveryMode(value.single)),
                  ),
                  const SizedBox(height: 8),
                  Text(session.deliveryMode == 'steer'
                      ? 'Guide the current turn at the next model step.'
                      : 'Wait for the current turn to finish, then start the next one.',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  const SizedBox(height: 24),
                  const Text('Dictation', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'live', label: Text('Live')),
                      ButtonSegment(value: 'on_stop', label: Text('On stop')),
                    ],
                    selected: {session.dictationMode},
                    onSelectionChanged: (value) => _run(() => session.chooseDictationMode(value.single)),
                  ),
                  const SizedBox(height: 8),
                  Text(session.dictationMode == 'live'
                      ? 'Show text while you speak. If live dictation is unavailable, transcribe when you stop.'
                      : 'Record first, then insert the transcription when you stop.',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  const SizedBox(height: 24),
                  _archivedTasks(context),
                  if (session.error case final error?)
                    Padding(padding: const EdgeInsets.only(top: 20), child: SelectableText(error,
                      style: TextStyle(color: Theme.of(context).colorScheme.error))),
                ],
              ),
            ))),
          ),
        ),
      ));
    } finally {
      _settingsOpen = false;
      await _run(session.cancelLogin);
      session.dismissLoginResult();
    }
  }

  Future<void> _signIn(String provider) async {
    final success = await session.signIn(provider, (url) async {
      if (await _desktop.invokeMethod<bool>('openLoginUrl', url) != true) {
        throw StateError('Could not open the browser');
      }
    });
    if (success && mounted) await _desktop.invokeMethod<void>('activate');
  }

  Widget _archivedTasks(BuildContext settingsContext) {
    final archived = [
      for (final project in session.projects)
        for (final task in project.tasks)
          if (task.archived) (project, task),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Archived tasks (${archived.length})', style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (archived.isEmpty)
          const Text('No archived tasks.', style: TextStyle(fontSize: 12, color: Colors.black54))
        else ...[
          const Text('Select a task to view its conversation. Restore to continue it.', style: TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 8),
          SizedBox(
            height: (archived.length * 80.0).clamp(80.0, 240.0),
            width: double.maxFinite,
            child: ListView.builder(
              itemCount: archived.length,
              itemBuilder: (context, index) {
                final (project, task) = archived[index];
                return ListTile(
                  key: ValueKey('archived:${task.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Tooltip(message: project.path, child: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  onTap: task.archiving ? null : () {
                    Navigator.pop(settingsContext);
                    unawaited(_run(() => _selectProject(project, task)));
                  },
                  trailing: TextButton(
                    onPressed: session.connected && !task.archiving
                        ? () => _run(() => session.setArchived(task, false))
                        : null,
                    child: Text(task.archiving ? 'Restoring…' : 'Restore'),
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _accountCard(Json provider) {
    final id = provider['id'] as String;
    final name = provider['auth'] == 'opencode' ? 'OpenCode' : provider['name'] as String;
    final status = provider['status'] as String;
    final connected = {'signed_in', 'refresh_required'}.contains(status);
    final working = session.signingIn && session.loginProvider == id;
    final available = session.connected && !session.signingIn && session.signingOut == null;
    return Container(
      key: ValueKey('account:$id'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xfffcfcfd), border: Border.all(color: const Color(0xffe8e9eb)), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (provider['auth'] == 'opencode') const Text('DeepSeek models', style: TextStyle(fontSize: 12, color: Colors.black54)),
          ])),
          Icon(connected ? Icons.check_circle : Icons.circle_outlined, size: 15, color: connected ? const Color(0xff296748) : Colors.black38),
          const SizedBox(width: 6),
          Text(_authLabel(status), style: const TextStyle(fontSize: 12)),
        ]),
        const SizedBox(height: 12),
        if (working) ...[
          Row(children: [
            const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
            Expanded(child: Text(session.loginMessage ?? 'Waiting for your browser…', style: const TextStyle(fontSize: 12))),
          ]),
          if (session.loginCode case final code?) Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 18))),
          Row(children: [
            TextButton(onPressed: session.loginUrl == null ? null : session.openLoginBrowser, child: const Text('Open browser')),
            TextButton(onPressed: () => _run(session.cancelLogin), child: const Text('Cancel')),
          ]),
        ] else
          Wrap(spacing: 8, children: [
            if (!connected)
              FilledButton(onPressed: available ? () => _run(() => _signIn(id)) : null, child: Text('Sign in to $name'))
            else
              OutlinedButton(onPressed: available ? () => session.signOut(id) : null, child: Text(session.signingOut == id ? 'Signing out…' : 'Sign out')),
            if (connected)
              TextButton(onPressed: available ? () => _run(() => _signIn(id)) : null, child: const Text('Switch account')),
          ]),
        if (session.loginProvider == id && session.loginError != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(session.loginError!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12))),
      ]),
    );
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on CancelledException {
      // The window was closed while this action was pending.
    } catch (error) {
      session.showError(error);
    }
  }

  Future<void> _addProject() => _run(() async {
    if (_picking) return;
    _picking = true;
    try {
      final paths = await MacosFilePicker().pick(
        MacosFilePickerMode.folder,
        allowsMultiple: false,
        dialogTitle: 'Open project',
      );
      try {
        if (mounted && paths != null && paths.isNotEmpty) {
          await session.addProject(paths.first.path);
        }
      } finally {
        for (final path in paths ?? <MacosFilePickerPath>[]) {
          await path.release();
        }
      }
    } finally {
      _picking = false;
    }
  });

  Future<void> _removeProject(Project project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${project.name}?'),
        content: const Text('Remove this project and its tasks from Happen. Running tasks will be stopped. The folder and saved task history will be kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Remove project')),
        ],
      ),
    );
    if (confirmed == true && mounted) await session.removeProject(project);
  }

  void _bindNavigation() {
    FocusManager.instance.removeEarlyKeyEventHandler(_navigateKey);
    FocusManager.instance.addEarlyKeyEventHandler(_navigateKey);
  }

  @override
  void reassemble() {
    super.reassemble();
    _bindNavigation();
  }

  KeyEventResult _navigateKey(KeyEvent event) {
    // Sidebar clicks can leave focus outside the workspace's shortcut ancestry.
    // Handle navigation before the focus tree, only while this route is current.
    if (!mounted || ModalRoute.of(context)?.isCurrent != true ||
        event is! KeyDownEvent && event is! KeyRepeatEvent) { return KeyEventResult.ignored; }
    final keyboard = HardwareKeyboard.instance;
    final primary = defaultTargetPlatform == TargetPlatform.macOS ? keyboard.isMetaPressed : keyboard.isControlPressed;
    final other = defaultTargetPlatform == TargetPlatform.macOS ? keyboard.isControlPressed : keyboard.isMetaPressed;
    if (event.logicalKey == LogicalKeyboardKey.keyB && primary && !other &&
        keyboard.isShiftPressed && !keyboard.isAltPressed && _hasSidebar) {
      if (event is KeyDownEvent) unawaited(_run(() => session.chooseSidebarOpen(!session.sidebarOpen)));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyJ && primary && !other &&
        !keyboard.isAltPressed && !keyboard.isShiftPressed && _canOpenTerminal) {
      if (event is KeyDownEvent) { _openTerminal(); }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyB && primary && !other &&
        !keyboard.isShiftPressed && !keyboard.isAltPressed && session.task != null && !_homeOpen) {
      if (event is KeyDownEvent) _toggleSidePanel();
      return KeyEventResult.handled;
    }
    if (!keyboard.isAltPressed || keyboard.isMetaPressed ||
        keyboard.isControlPressed || keyboard.isShiftPressed) { return KeyEventResult.ignored; }
    final offset = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => -1,
      LogicalKeyboardKey.arrowDown => 1,
      _ => 0,
    };
    if (offset == 0) return KeyEventResult.ignored;
    _selectAdjacentTask(offset);
    return KeyEventResult.handled;
  }

  void _selectAdjacentTask(int offset) {
    final tasks = session.openCodeLayout == OpenCodeLayout.inbox
      ? [for (final project in session.projects) if (!project.removing)
          for (final task in project.tasks) if (!task.archived) (project, task)]
      : session.openTasks;
    final index = tasks.indexWhere((entry) => entry.$2 == session.task);
    final next = index < 0 ? (offset > 0 ? 0 : tasks.length - 1) : index + offset;
    if (next >= 0 && next < tasks.length) _openTask(tasks[next].$1, tasks[next].$2);
  }

  Future<void> _selectProject(Project project, [DesktopTask? task]) {
    if (_homeOpen) setState(() => _homeOpen = false);
    session.viewingConversation = true;
    return session.select(project, task);
  }

  Future<void> _newChat() async {
    if (_homeOpen) setState(() => _homeOpen = false);
    final project = session.project;
    if (project == null || !project.available || project.removing) { await _addProject(); return; }
    await _selectProject(project);
    if (mounted && session.project == project && session.task == null) _composer.currentState?._focus.requestFocus();
  }

  bool get _hasSidebar => session.openCodeLayout != OpenCodeLayout.top;

  void _showHome({bool search = false}) {
    session.viewingConversation = false;
    setState(() => _homeOpen = true);
    if (search) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _homeOpen) _sessionSearchFocus.requestFocus();
      });
    }
  }

  void _openTask(Project project, DesktopTask task) {
    session.viewingConversation = true;
    setState(() => _homeOpen = false);
    unawaited(_run(() => session.select(project, task)));
  }

  void _openDraft(Project project) {
    setState(() => _homeOpen = false);
    unawaited(_run(() async {
      await _selectProject(project);
      if (mounted) _composer.currentState?._focus.requestFocus();
    }));
  }

  bool get _canOpenTerminal => session.project?.available == true && session.project?.removing != true &&
      session.task?.archived != true && session.task?.archiving != true;

  (String, String?)? get _terminalScope => _canOpenTerminal ? (session.project!.checkoutKey, session.task?.id) : null;

  void _openTerminal() {
    final project = session.project;
    if (!_canOpenTerminal || project == null) return;
    if (_homeOpen) setState(() => _homeOpen = false);
    session.terminals.open(_terminalScope!, project.path);
  }

  void _toggleSidePanel() {
    if (session.task case final task?) {
      session.toggleSidePanel(task);
      if (!session.panelsFor(task).opened) _composer.currentState?._focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) => FocusScope(
    autofocus: true,
    child: Scaffold(
      body: LayoutBuilder(builder: (context, constraints) => ListenableBuilder(
        listenable: _viewChanges,
        builder: (context, _) => _workspace(context, constraints),
      )),
    ),
  );

  Widget _workspace(BuildContext context, BoxConstraints constraints) {
    final tasks = session.projects.expand((project) => project.tasks).toSet();
    session.viewingConversation = !_homeOpen;
    final minSidebarWidth = 136.0;
    final maxSidebarWidth = (constraints.maxWidth - 488).clamp(minSidebarWidth, 640.0).toDouble();
    final savedWidth = session.openCodeSidebarWidth;
    final sidebarWidth = (_dragSidebarWidth ?? savedWidth).clamp(minSidebarWidth, maxSidebarWidth).toDouble();
    final pane = _conversationPane(context, tasks);
    if (!_hasSidebar) {
      return ColoredBox(color: const Color(0xfff9f9f9), child: Column(children: [
        OpenCodeTopBar(session: session, home: _homeOpen, leadingInset: _trafficInset,
          onHome: _showHome, onSearch: () => _showHome(search: true),
          onNew: () => unawaited(_run(_newChat)), onSettings: _settings,
          onSelect: _openTask, onArchive: (task, archived) => unawaited(_run(() => _archiveTask(task, archived)))),
        Expanded(child: pane),
      ]));
    }
    return ColoredBox(color: const Color(0xfff9f9f9), child: DesktopSidebarFrame(
      open: session.sidebarOpen, width: sidebarWidth,
      resizerOffset: 4, resizing: _dragSidebarWidth != null,
      collapsedInset: _trafficInset == 0 ? 18 : _trafficInset,
      onToggle: () => unawaited(_run(() => session.chooseSidebarOpen(!session.sidebarOpen))),
      unread: session.openTasks.any((entry) => !entry.$2.running && entry.$2.lastActivity > (session.viewedTasks[entry.$2.id] ?? -1)),
      sidebar: OpenCodeSidebar(session: session, home: _homeOpen, windowControls: _trafficInset > 0,
            onHome: _showHome, onSearch: () => _showHome(search: true),
            onNew: () => unawaited(_run(_newChat)), onSettings: _settings,
            onSelect: _openTask, onArchive: (task, archived) => unawaited(_run(() => _archiveTask(task, archived))))
        ,
      resizer: _sidebarResizer(sidebarWidth, minSidebarWidth, maxSidebarWidth),
      child: pane,
    ));
  }

  Widget _sidebarResizer(double sidebarWidth, double minSidebarWidth, double maxSidebarWidth) =>
    SidebarResizer(key: const ValueKey('sidebar-resizer'), size: sidebarWidth,
      min: minSidebarWidth, max: maxSidebarWidth,
      onResize: (width) => setState(() => _dragSidebarWidth = width),
      onResizeEnd: (width) {
        unawaited(_run(() => session.chooseSidebarWidth(width)));
        setState(() => _dragSidebarWidth = null);
      },
      onCancel: () => setState(() => _dragSidebarWidth = null));

  Widget _conversationPane(BuildContext context, Set<DesktopTask> tasks) {
    final home = _homeOpen;
    return TerminalWorkspace(key: _conversationPaneKey, controller: session.terminals, scope: home ? null : _terminalScope,
      child: ConversationTypography(
          child: Padding(padding: const EdgeInsets.all(8), child: SessionPanelWorkspace(
            session: session, task: home ? null : session.task,
            onReturnFocus: () => _composer.currentState?._focus.requestFocus(),
            child: SessionPanelFrame(child: Stack(fit: StackFit.expand, children: [
              Offstage(offstage: home, child: Column(children: [
                _header(context),
                Expanded(child: ConversationDataScope(client: session.client, providers: session.providers, child: ConversationDeck(
                    task: session.task,
                    tasks: tasks,
                    directory: session.project?.path ?? '',
                    empty: _empty(context),
                    onRetry: (task) => unawaited(_run(() => session.loadHistory(task))),
                    onLoadEarlier: (task) => unawaited(_run(() => session.loadEarlier(task))),
                ))),
                if (session.error case final error?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 8, 28, 0),
                    child: SelectableText(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (session.project != null && session.project!.available && session.task?.archived != true)
                  McpConversationAuth(key: ValueKey(session.client), client: session.client),
                if (session.project?.removing == true)
                  const Padding(padding: EdgeInsets.all(20), child: Text('Removing project…'))
                else if (session.project?.available == false)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Text('Project folder is unavailable', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      SelectableText(session.project!.path, style: const TextStyle(color: Colors.black54)),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, children: [
                        TextButton(onPressed: () => _run(() => _removeProject(session.project!)), child: const Text('Remove project')),
                        if (session.task?.running == true)
                          TextButton(onPressed: session.connected ? () => _run(session.stop) : null, child: const Text('Stop task')),
                      ]),
                    ]),
                  )
                else if (session.task?.archived == true)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: FilledButton.icon(
                      onPressed: () => _run(() => _archiveTask(session.task!, false)),
                      icon: const Icon(Icons.unarchive_outlined),
                      label: const Text('Restore task to continue'),
                    ),
                  )
                else if (session.project != null)
                  _Composer(key: _composer, session: session),
              ])),
              if (home) OpenCodeHome(session: session, focusNode: _sessionSearchFocus,
                onSelect: _openTask, onNew: _openDraft, onAddProject: () => unawaited(_addProject())),
            ])),
          )),
        ),
    );
  }

  Future<void> _archiveTask(DesktopTask task, bool archived) async {
    final project = session.projects.where((project) => project.tasks.contains(task)).firstOrNull;
    if (project == null || project.removing) return;
    await session.setArchived(task, archived);
    if (!mounted) return;
    if (!archived) {
      await _selectProject(project, task);
    } else {
      ScaffoldMessenger.of(context)..clearSnackBars()..showSnackBar(SnackBar(
        content: const Text('Task archived'),
        duration: const Duration(seconds: 3),
        persist: false,
        action: SnackBarAction(label: 'Undo', onPressed: () => _run(() => _archiveTask(task, false))),
      ));
    }
  }

  Widget _header(BuildContext context) => DesktopWindowDragRegion(child: AnimatedPadding(
    duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
    padding: EdgeInsets.only(left: _hasSidebar && !session.sidebarOpen ? (_trafficInset == 0 ? 50 : _trafficInset + 24) : 24, right: 24),
    child: SizedBox(height: 48, child: Row(
      children: [
        if (session.task != null && session.project != null) ...[
          Flexible(child: Text(session.project!.name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: opencodeMuted))),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text('/', style: TextStyle(color: Color(0xffc8cacf)))),
        ],
        Expanded(
          child: Text(
            session.task?.title ?? session.project?.name ?? 'Your workspace',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w500,
              letterSpacing: -.04,
              fontVariations: const [FontVariation('wght', 530)],
              color: opencodeInk),
          ),
        ),
        if (session.task != null)
          ContextUsageIndicator(messages: session.task!.messages.values,
            limit: session.task!.contextLimit ?? session.modelInfo?['context_limit'] as num?,
            onPressed: () {
              session.openSessionPanel(session.task!, contextPanel, toggle: true);
              if (!session.panelsFor(session.task!).opened) _composer.currentState?._focus.requestFocus();
            }),
        if (session.project != null)
          IconButton(
            tooltip: 'Open terminal (${defaultTargetPlatform == TargetPlatform.macOS ? '⌘J' : 'Ctrl+J'})',
            onPressed: _canOpenTerminal ? _openTerminal : null,
            icon: const Icon(Icons.terminal_outlined, size: 17, color: Color(0xff777b82)),
          ),
        if (session.project != null)
          IconButton(
            tooltip: 'New task',
            onPressed: session.project!.available && !session.project!.removing ? () => _run(_newChat) : null,
            icon: const Icon(Icons.edit_square, size: 17, color: Color(0xff777b82)),
          ),
        if (session.task != null && session.panelLayouts[session.task!.id]?.opened != true)
          IconButton(key: const ValueKey('toggle-side-panel'),
            tooltip: 'Toggle side panel (${defaultTargetPlatform == TargetPlatform.macOS ? '⌘B' : 'Ctrl+B'})',
            onPressed: _toggleSidePanel,
            icon: const SidePanelIcon(opened: false)),
      ],
    )),
  ));

  Widget _empty(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (session.project == null) ...[
            const Icon(Icons.folder_open_outlined, size: 32, color: Color(0xff8b8e95)),
            const SizedBox(height: 20),
          ],
          Text(
            session.project == null
                ? 'Start with a project'
                : 'What are we working on?',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24,
              fontWeight: FontWeight.w500, letterSpacing: -.8, color: const Color(0xff292b30)),
          ),
          const SizedBox(height: 12),
          Text(
            session.project == null
                ? 'Open a folder, then start a task.'
                : 'Each task keeps its own conversation.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Color(0xff979aa0)),
          ),
          if (session.project == null) ...[
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _addProject,
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('Open project'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _Composer extends StatefulWidget {
  const _Composer({super.key, required this.session});
  final DesktopSession session;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  late String _draftKey = widget.session.draftKey;
  late ComposerTextController _text = ComposerTextController(
    text: widget.session.drafts[_draftKey] ?? '',
    files: widget.session.fileDrafts[_draftKey] ?? const [],
  );
  final _focus = FocusNode();
  final _autocomplete = GlobalKey<ComposerAutocompleteState>();
  var _attachmentLifetime = CancellationToken();
  bool _receivingAttachments = false, _draggingAttachments = false;
  List<ComposerAttachment> get _attachments => widget.session.attachmentDrafts[_draftKey] ?? const [];
  late Object _voiceOwner = Object();
  DictationService? _boundVoice;
  ComposerDictationSession? _voiceText;
  bool _finishingVoice = false, _disposing = false;
  DictationService get _voice => widget.session.dictation;
  bool get _ownsVoice => identical(_voice.owner, _voiceOwner);
  bool get _dictating => _ownsVoice && (_voice.active || _finishingVoice);
  DictationUiPhase get _voicePhase => !_ownsVoice ? DictationUiPhase.idle : switch (_voice.phase) {
    DictationPhase.idle => _finishingVoice ? DictationUiPhase.transcribing : DictationUiPhase.idle,
    DictationPhase.starting => DictationUiPhase.starting,
    DictationPhase.recording => DictationUiPhase.recording,
    DictationPhase.transcribing => DictationUiPhase.transcribing,
    DictationPhase.failed => _voice.canRetry ? DictationUiPhase.retry : DictationUiPhase.idle,
  };

  void _bindVoice() {
    if (identical(_boundVoice, _voice)) return;
    _boundVoice?.removeListener(_voiceChanged);
    _boundVoice = _voice;
    _boundVoice!.addListener(_voiceChanged);
  }

  void _voiceChanged() {
    if (!mounted) return;
    if (_ownsVoice && _voice.active) {
      _voiceText?.update(_voice.transcript);
    } else if (_ownsVoice && _voice.canRetry) {
      _voiceText?.pauseForRecovery();
    } else if (!_ownsVoice || !_finishingVoice) {
      _voiceText?.dispose(cancel: true);
      _voiceText = null;
    }
    setState(() {});
  }

  Future<void> _startVoice() async {
    if (_voice.active || _finishingVoice || !widget.session.connected || widget.session.submitting) return;
    _voiceText?.dispose();
    _voiceText = ComposerDictationSession(_text, (range, text) {
      final editorContext = _focus.context;
      if (!_disposing && editorContext != null && editorContext.mounted) {
        Actions.invoke(editorContext, ReplaceTextIntent(_text.value, text, range, SelectionChangedCause.keyboard));
      } else {
        // Navigation may already have detached the editable widget. Restore the
        // saved draft through its controller without looking up widget actions.
        _text.value = TextEditingValue(text: _text.text.replaceRange(range.start, range.end, text),
          selection: TextSelection.collapsed(offset: range.start + text.length));
      }
    });
    _focus.requestFocus();
    await _voice.start(owner: _voiceOwner, liveTranscription: widget.session.dictationMode == 'live',
      onRecordingLimit: () => unawaited(_finishVoice(DictationAction.insert)));
  }

  Future<void> _cancelVoice() async {
    if (!_ownsVoice) return;
    _voiceText?.dispose(cancel: true);
    _voiceText = null;
    await _voice.cancel();
    if (mounted) _focus.requestFocus();
  }

  Future<void> _finishVoice(DictationAction action, {bool retry = false}) async {
    if (!_ownsVoice || _finishingVoice) return;
    final owner = _voiceOwner;
    setState(() => _finishingVoice = true);
    try {
      final result = retry ? await _voice.retry(action) : await _voice.stop(action);
      if (!mounted || !identical(_voiceOwner, owner) || !_ownsVoice || result == null) return;
      final inserted = await _voiceText?.finish(result.text) ?? false;
      if (!mounted || !identical(_voiceOwner, owner) || !_ownsVoice || !inserted) return;
      _voiceText?.dispose();
      _voiceText = null;
      _focus.requestFocus();
      if (result.action == DictationAction.send) await _sendPrompt();
    } finally {
      if (identical(_voiceOwner, owner)) {
        _finishingVoice = false;
        if (mounted) setState(() {});
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _text.addListener(_saveDraft);
    _focus.requestFocus();
  }

  @override
  void didUpdateWidget(_Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_draftKey == widget.session.draftKey) return;
    _attachmentLifetime.cancel();
    _attachmentLifetime = CancellationToken();
    _receivingAttachments = false;
    _draggingAttachments = false;
    _boundVoice?.removeListener(_voiceChanged);
    _voiceText?.dispose(cancel: true);
    _voiceText = null;
    if (_boundVoice != null && identical(_boundVoice!.owner, _voiceOwner)) unawaited(_boundVoice!.cancel());
    _boundVoice = null;
    _voiceOwner = Object();
    _finishingVoice = false;
    final previous = _text;
    previous.removeListener(_saveDraft);
    _draftKey = widget.session.draftKey;
    _text = ComposerTextController(
      text: widget.session.drafts[_draftKey] ?? '',
      files: widget.session.fileDrafts[_draftKey] ?? const [],
    )..addListener(_saveDraft);
    // The editor and autocomplete detach their listeners during this build.
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  void _saveDraft() {
    if (_text.text.isEmpty) {
      widget.session.drafts.remove(_draftKey);
    } else {
      widget.session.drafts[_draftKey] = _text.text;
    }
    final files = _text.files;
    if (files.isEmpty) {
      widget.session.fileDrafts.remove(_draftKey);
    } else {
      widget.session.fileDrafts[_draftKey] = files;
    }
  }

  Future<void> _copy({bool cut = false}) async {
    final controller = _text;
    final before = _text.value, selection = _text.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    final text = _text.serializeRange(selection.start, selection.end);
    await Clipboard.setData(ClipboardData(text: text));
    if (cut && mounted && identical(_text, controller) && _text.value == before && !widget.session.submitting) {
      final editor = _focus.context;
      if (editor != null && editor.mounted) Actions.invoke(editor, ReplaceTextIntent(before, '', selection, SelectionChangedCause.keyboard));
    }
  }

  void _addAttachments(List<ComposerAttachment> additions) {
    if (!mounted) return;
    setState(() {
      final draft = widget.session.attachmentDrafts.putIfAbsent(_draftKey, () => []);
      for (final attachment in additions) {
        if (!draft.any((existing) => existing.path == attachment.path)) draft.add(attachment);
      }
    });
    _focus.requestFocus();
  }

  Future<void> _paste(SelectionChangedCause cause) async {
    if (_receivingAttachments || widget.session.submitting || _dictating || !widget.session.connected) return;
    final before = _text.value, lifetime = _attachmentLifetime;
    setState(() => _receivingAttachments = true);
    try {
      final snapshot = await readComposerClipboard(widget.session.attachmentDirectory, lifetime);
      if (!mounted || lifetime.isCancelled) {
        for (final attachment in snapshot.attachments) { await attachment.discard(); }
        return;
      }
      if (snapshot.attachments.isNotEmpty) {
        _addAttachments(snapshot.attachments);
      } else if (_text.text == before.text && snapshot.text != null) {
        final current = _text.value;
        final range = current.selection.isValid ? current.selection : TextSelection.collapsed(offset: current.text.length);
        final editor = _focus.context;
        if (editor != null && editor.mounted) {
          Actions.invoke(editor, ReplaceTextIntent(current, snapshot.text!, range, cause));
        }
      }
    } on CancelledException {
      // Leaving this composer owns the pending native snapshot.
    } catch (error) {
      if (mounted && !lifetime.isCancelled) widget.session.showError(error);
    } finally {
      if (mounted && identical(_attachmentLifetime, lifetime)) setState(() => _receivingAttachments = false);
    }
  }

  Future<void> _drop(DropDetails details) async {
    if (_receivingAttachments || widget.session.submitting) return;
    final lifetime = _attachmentLifetime;
    setState(() => _receivingAttachments = true);
    try {
      final attachments = await receiveComposerDrop(details, widget.session.attachmentDirectory, lifetime);
      if (mounted && !lifetime.isCancelled) {
        _addAttachments(attachments);
      } else {
        for (final attachment in attachments) { await attachment.discard(); }
      }
    } on CancelledException {
      // The source is released by DropTarget after this operation settles.
    } catch (error) {
      if (mounted && !lifetime.isCancelled) widget.session.showError(error);
    } finally {
      if (mounted && identical(_attachmentLifetime, lifetime)) setState(() => _receivingAttachments = false);
    }
  }

  Future<void> _pickAttachments() async {
    if (_receivingAttachments || widget.session.submitting || _dictating) return;
    final lifetime = _attachmentLifetime;
    setState(() => _receivingAttachments = true);
    try {
      final paths = await MacosFilePicker().pick(MacosFilePickerMode.file,
        allowsMultiple: true, initialDirectory: widget.session.project?.path, dialogTitle: 'Attach files');
      try {
        lifetime.throwIfCancelled();
        if (mounted) _addAttachments([for (final path in paths ?? <MacosFilePickerPath>[]) composerAttachmentForFile(path.path)]);
      } finally {
        for (final path in paths ?? <MacosFilePickerPath>[]) { await path.release(); }
      }
    } on CancelledException {
      // A different task now owns the composer.
    } catch (error) {
      if (mounted && !lifetime.isCancelled) widget.session.showError(error);
    } finally {
      if (mounted && identical(_attachmentLifetime, lifetime)) setState(() => _receivingAttachments = false);
    }
  }

  Future<void> _submit() async {
    if (!_text.value.composing.isCollapsed) return;
    if (_dictating) {
      await _finishVoice(DictationAction.send);
      return;
    }
    await _sendPrompt();
  }

  Future<void> _sendPrompt() async {
    if (_receivingAttachments) return;
    if (_autocomplete.currentState?.consumeCommand() == true) return;
    final controller = _text, draftKey = _draftKey;
    final draft = _text.text;
    final prompt = _text.serializePrompt();
    final attachments = List<ComposerAttachment>.of(_attachments);
    try {
      final accepted = await widget.session.send(prompt, attachments: attachments);
      if (accepted) {
        if (mounted && identical(_text, controller)) _autocomplete.currentState?.dismiss();
        if (widget.session.drafts[draftKey] == draft) {
          widget.session.drafts.remove(draftKey);
          widget.session.fileDrafts.remove(draftKey);
        }
        final ids = attachments.map((attachment) => attachment.id).toSet();
        widget.session.attachmentDrafts[draftKey]?.removeWhere((attachment) => ids.contains(attachment.id));
        if (widget.session.attachmentDrafts[draftKey]?.isEmpty == true) widget.session.attachmentDrafts.remove(draftKey);
        for (final attachment in attachments) {
          if (attachment.image || !widget.session.client.sharedFilesystem) await attachment.discard();
        }
        if (mounted && identical(_text, controller) && _text.text == draft) _text.clear();
        if (mounted) setState(() {});
      }
    } on CancelledException {
      // Application exit owns cancellation.
    }
  }

  Future<void> _stop() async {
    try {
      await widget.session.stop();
    } on CancelledException {
      // Application exit owns cancellation.
    } catch (error) {
      widget.session.showError(error);
    }
  }

  void _newline() {
    final value = _text.value;
    if (!value.composing.isCollapsed) return;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    _text.value = TextEditingValue(
      text: value.text.replaceRange(selection.start, selection.end, '\n'),
      selection: TextSelection.collapsed(offset: selection.start + 1),
    );
    widget.session.drafts[_draftKey] = _text.text;
  }

  @override
  void dispose() {
    _disposing = true;
    _attachmentLifetime.cancel();
    _boundVoice?.removeListener(_voiceChanged);
    _voiceText?.dispose(cancel: true);
    if (_boundVoice != null && identical(_boundVoice!.owner, _voiceOwner)) unawaited(_boundVoice!.cancel());
    _focus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _bindVoice();
    final session = widget.session;
    final running = session.task?.running == true;
    final available =
        session.connected &&
        !_receivingAttachments &&
        !session.submitting &&
        session.task?.loading != true &&
        session.task?.loadError == null;
    return DropTarget(
      enabled: session.connected && !session.submitting && !_receivingAttachments,
      acceptedKinds: const {DropItemKind.file, DropItemKind.directory},
      onDrop: _drop,
      onEnter: (_) => setState(() => _draggingAttachments = true),
      onLeave: () { if (mounted) setState(() => _draggingAttachments = false); },
      child: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: opencodeSessionWidth),
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
          CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): () {
                if (!_text.value.composing.isCollapsed) return;
                if (_ownsVoice && (_dictating || _voice.phase == DictationPhase.failed)) unawaited(_cancelVoice());
              },
              const SingleActivator(LogicalKeyboardKey.enter, shift: true): _newline,
              const SingleActivator(
                LogicalKeyboardKey.enter,
                includeRepeats: false,
              ): () {
                if (available) unawaited(_submit());
              },
              const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
                if (available) unawaited(_submit());
              },
              const SingleActivator(
                LogicalKeyboardKey.enter,
                control: true,
              ): () {
                if (available) unawaited(_submit());
              },
            },
            child: Actions(actions: {CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
              onInvoke: (intent) { unawaited(_copy(cut: intent.collapseSelection)); return null; }),
              PasteTextIntent: ComposerPasteAction(
              enabled: session.connected && !session.submitting && !_receivingAttachments && !_dictating, paste: _paste)},
            child: ComposerAutocomplete(
              key: _autocomplete,
              controller: _text,
              focusNode: _focus,
              client: session.client,
              cwd: session.project!.path,
              enabled: session.connected && !session.submitting && !_dictating,
              session: session,
              commands: {
                '/new': (description: 'Start a new session', run: () => unawaited(session.select(session.project!))),
                if (defaultTargetPlatform == TargetPlatform.macOS)
                  '/attach': (description: 'Attach files and images', run: () => unawaited(_pickAttachments())),
                '/history': (description: 'Search previous prompts', run: () => _autocomplete.currentState?.openHistory()),
                if (session.task != null) '/context': (description: 'Inspect session context',
                  run: () => session.openSessionPanel(session.task!, contextPanel)),
                '/terminal': (description: 'Open the project terminal', run: () => session.terminals.open(
                  (session.project!.checkoutKey, session.task?.id), session.project!.path)),
              },
              child: DecoratedBox(
                key: const ValueKey('conversation-composer'),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _draggingAttachments ? Theme.of(context).colorScheme.primary
                    : const Color(0x1f000000),
                    width: _draggingAttachments ? 2 : .5),
                  boxShadow: const [
                    BoxShadow(color: Color(0x0a000000), blurRadius: 4, offset: Offset(0, 2)),
                    BoxShadow(color: Color(0x14000000), blurRadius: 2, spreadRadius: -1, offset: Offset(0, 1)),
                  ],
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(8, 0, 8, 0),
                  child: Column(
                    children: [
                      if (_draggingAttachments) const Padding(padding: EdgeInsets.all(8), child: Text('Drop images or files to attach')),
                      if (_attachments.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Align(
                        alignment: Alignment.centerLeft,
                        child: AttachmentRail(attachments: _attachments.map((attachment) => attachment.toJson()).toList(),
                          onRemove: session.submitting ? null : (index) {
                            final removed = _attachments[index];
                            setState(() => widget.session.attachmentDrafts[_draftKey]!.remove(removed));
                            unawaited(removed.discard());
                          }),
                      )),
                      if (_receivingAttachments || session.attachmentStatus != null) Row(children: [
                        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(session.attachmentStatus ?? 'Adding attachments…', style: const TextStyle(fontSize: 12))),
                        if (session.attachmentStatus != null) IconButton(tooltip: 'Cancel upload', onPressed: session.cancelUpload, icon: const Icon(Icons.close, size: 16)),
                      ]),
                      if (_ownsVoice && _voice.canRetry)
                        Tooltip(message: _voice.error ?? 'Dictation stopped', child: DictationRecoveryRail(
                          phase: DictationRecoveryPhase.failed,
                          onDismiss: () => unawaited(_cancelVoice()),
                          onRetry: () => unawaited(_finishVoice(DictationAction.insert, retry: true)),
                        ))
                      else if (_ownsVoice && _voice.error != null)
                        Semantics(liveRegion: true, child: Row(children: [
                          Expanded(child: Text(_voice.error!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error))),
                          if (_voice.microphonePermissionDenied)
                            TextButton(onPressed: _voice.openMicrophoneSettings, child: const Text('Open microphone settings')),
                          IconButton(tooltip: 'Dismiss dictation error', onPressed: _cancelVoice, icon: const Icon(Icons.close, size: 16)),
                        ])),
                      ComposerEditor(
                        controller: _text,
                        focusNode: _focus,
                        enabled: session.connected,
                        paste: _paste, copy: _copy,
                      ),
                      SizedBox(height: 44, child: Row(
                        children: [
                          PopupMenuButton<String>(tooltip: 'Add context or commands', enabled: available && !_dictating,
                            padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 220),
                            onSelected: (value) {
                              switch (value) {
                                case 'context': _autocomplete.currentState?.openContext();
                                case 'commands': _autocomplete.currentState?.openCommands();
                                case 'history': _autocomplete.currentState?.openHistory();
                                case 'attach': unawaited(_pickAttachments());
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(value: 'context', child: ListTile(dense: true, contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.alternate_email_rounded, size: 16), title: Text('Add context'), trailing: Text('@'))),
                              const PopupMenuItem(value: 'commands', child: ListTile(dense: true, contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.terminal_rounded, size: 16), title: Text('Commands'), trailing: Text('/'))),
                              const PopupMenuItem(value: 'history', child: ListTile(dense: true, contentPadding: EdgeInsets.zero,
                                leading: Icon(Icons.history_rounded, size: 16), title: Text('Prompt history'), trailing: Text('⇧↑'))),
                              if (defaultTargetPlatform == TargetPlatform.macOS)
                                const PopupMenuItem(value: 'attach', child: ListTile(dense: true, contentPadding: EdgeInsets.zero,
                                  leading: Icon(Icons.attach_file_rounded, size: 16), title: Text('Attach files'))),
                            ],
                            child: const SizedBox.square(dimension: 28,
                              child: Icon(Icons.add_rounded, size: 20, color: Color(0xff656971)))),
                          if (_dictating) ...[
                            DictationCancelButton(onCancel: () => unawaited(_cancelVoice())),
                            const SizedBox(width: 8),
                          ],
                          Expanded(child: Row(mainAxisAlignment: MainAxisAlignment.start, children: [
                            Flexible(child: ComposerModelPicker(session: session, enabled: available)),
                          ])),
                          const SizedBox(width: 8),
                          if (defaultTargetPlatform == TargetPlatform.macOS) ...[
                            DictationButton(
                              phase: _voicePhase,
                              amplitude: _voice.amplitude,
                              enabled: available && (!_voice.active || _ownsVoice),
                              onStart: () => unawaited(_startVoice()),
                              onStop: () => unawaited(_finishVoice(DictationAction.insert)),
                              onCancel: () => unawaited(_cancelVoice()),
                              onRetry: () => unawaited(_finishVoice(DictationAction.insert, retry: true)),
                            ),
                            const SizedBox(width: 8),
                          ],
                          ValueListenableBuilder<TextEditingValue>(valueListenable: _text, builder: (context, value, _) {
                            final hasContent = value.text.trim().isNotEmpty || _attachments.isNotEmpty;
                            final stopWorking = running && !hasContent && !_dictating;
                            final dictationCanSend = _dictating && _voice.phase == DictationPhase.recording && !_finishingVoice;
                            return IconButton.filled(
                            style: IconButton.styleFrom(
                              backgroundColor: const Color(0xff1a1c1f), foregroundColor: Colors.white,
                              disabledBackgroundColor: const Color(0xffececef), disabledForegroundColor: const Color(0xffb0b3b9),
                              minimumSize: const Size.square(32), maximumSize: const Size.square(32), padding: EdgeInsets.zero,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            tooltip: stopWorking ? 'Stop task and clear pending messages' : running
                                ? (session.deliveryMode == 'steer'
                                      ? 'Steer task'
                                      : 'Queue message')
                                : 'Send message',
                            onPressed: stopWorking ? (session.connected ? _stop : null) : available && session.authenticated &&
                                (dictationCanSend || !_dictating && hasContent)
                                ? _submit
                                : null,
                            icon: Icon(
                              stopWorking ? Icons.stop_rounded : running && session.deliveryMode == 'queue'
                                  ? Icons.playlist_add
                                  : Icons.arrow_upward_rounded,
                              size: 20,
                            ),
                          );
                          }),
                        ],
                      )),
                      if (!session.authenticated)
                        const Align(alignment: Alignment.centerLeft, child: Text('Sign in to the selected provider to send',
                          style: TextStyle(fontSize: 11, color: Colors.black38))),
                    ],
                  ),
                ),
              ),
            )),
          ),
          ]),
        ),
      ),
      ),
    );
  }
}

String _authLabel(String status) => switch (status) {
  'signed_in' => 'Signed in',
  'refresh_required' => 'Login saved',
  'expired' => 'Login expired',
  'invalid' => 'Check login',
  _ => 'Not signed in',
};
