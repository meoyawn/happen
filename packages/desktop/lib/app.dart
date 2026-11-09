import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_file_picker/macos_file_picker.dart';
import 'package:protocol/protocol.dart';
import 'package:desktop_drop/desktop_drop.dart';

import 'conversation.dart';
import 'conversation_annotations.dart';
import 'command_menu.dart';
import 'archived_sessions.dart';
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
import 'dictation_state.dart';
import 'dictation_controls.dart';
import 'desktop_toast.dart';
import 'file_autocomplete.dart';
import 'model_picker.dart';
import 'new_session.dart';
import 'mcp_conversation.dart';
import 'project_avatar.dart';
import 'session.dart';
import 'session_question.dart';
import 'sidebar_frame.dart';
import 'sidebar_resizer.dart';
import 'settings_screen.dart';
import 'workspace_navigation.dart';
import 'window_chrome.dart';
import 'terminal.dart';
import 'machines.dart';
import 'thread_machine_picker.dart';
import 'project_details.dart';

class DesktopView extends StatefulWidget {
  const DesktopView({super.key, required this.session, this.machinePicker, this.machines});
  final DesktopSession session;
  final Widget? machinePicker;
  final MachinesController? machines;

  @override
  State<DesktopView> createState() => _DesktopViewState();
}

class _DesktopViewState extends State<DesktopView> {
  static const _desktop = MethodChannel('happen/desktop');
  DesktopSession get session => widget.machines?.active ?? widget.session;
  DesktopSession get _sidebar => widget.machines?.local ?? session.sidebar;
  List<DesktopSession> get _sources => widget.machines?.sessions.map((machine) => machine.session).toList() ?? [session];
  DesktopSession _source(Project project) => _sources.firstWhere((source) => source.projects.contains(project));
  DesktopSession _taskSource(DesktopTask task) => _sources.firstWhere((source) => source.projects.any((project) => project.tasks.contains(task)));
  bool _picking = false, _settingsOpen = false;
  bool _commandMenuOpen = false;
  bool get _homeOpen => !session.viewingConversation;
  final _windowChrome = ValueNotifier((fullscreen: false, trafficLightsEnd: 85.0));
  String? _nativeLayout;
  final _sessionSearchFocus = FocusNode();
  final _projectMenu = MenuController();
  double? _dragSidebarWidth;
  final _composer = GlobalKey<_ComposerState>();
  final _conversationPaneKey = GlobalKey();
  final _navigationHistory = <String>[];
  int _navigationIndex = -1;
  String? _sidebarProjectKey;

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

  Listenable get _viewChanges => Listenable.merge([session, _windowChrome, if (_homeOpen) widget.machines]);
  double get _trafficInset => defaultTargetPlatform == TargetPlatform.macOS && !_windowChrome.value.fullscreen ? _windowChrome.value.trafficLightsEnd + 16 : 0;

  void _applyWindowChrome(Object? value) {
    if (!mounted || value is! Map) return;
    final end = value['trafficLightsEnd'];
    _windowChrome.value = (fullscreen: value['fullscreen'] == true,
      trafficLightsEnd: end is num ? end.toDouble() : _windowChrome.value.trafficLightsEnd);
  }

  void _syncWindowChrome() {
    if (defaultTargetPlatform != TargetPlatform.macOS) return;
    const layout = 'side';
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
    oldWidget.session.removeListener(_rememberNavigation);
    _bindNavigation();
    session.addListener(_syncWindowChrome);
    _syncWindowChrome();
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_navigateKey);
    session.removeListener(_syncWindowChrome);
    session.removeListener(_rememberNavigation);
    _desktop.setMethodCallHandler(null);
    _sessionSearchFocus.dispose();
    _windowChrome.dispose();
    super.dispose();
  }

  Future<void> _settings({String page = 'preferences', Project? project}) async {
    if (_settingsOpen || !mounted) return;
    _settingsOpen = true;
    try {
      await session.dictation.cancel();
      if (!mounted) return;
      await Navigator.of(context).push<void>(PageRouteBuilder(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (context, _, _) => ListenableBuilder(
          listenable: Listenable.merge([_viewChanges, widget.machines]),
          builder: (context, _) => DesktopSettingsScreen(
            session: session, run: _run,
            machines: widget.machines,
            initialPage: page, initialProject: project,
            addProject: _addProject,
            openProject: (project) async {
              Navigator.pop(context);
              await _run(() => _selectProject(project));
            },
            removeProject: (project) => _run(() => _removeProject(project)),
            windowControls: defaultTargetPlatform == TargetPlatform.macOS && !_windowChrome.value.fullscreen,
            accounts: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final provider in session.providers) _accountCard(provider),
            ]),
            archived: ArchivedSessions(session: session, run: _run),
          ),
        ),
      ));
    } finally {
      _settingsOpen = false;
      await _run(session.cancelLogin);
      session.dismissLoginResult();
    }
  }

  Future<void> _commandMenu({bool pickProject = false}) async {
    if (_commandMenuOpen || !mounted) return;
    _commandMenuOpen = true;
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final task = session.task;
    try {
      await showDialog<void>(
        context: context,
        barrierColor: const Color(0x22000000),
        builder: (context) => CommandMenu(
          session: session,
          sources: _sources,
          pickProject: pickProject,
          onNewThread: (project) => unawaited(_run(() => _newChat(project))),
          onAddProject: () => unawaited(_addProject()),
          actions: [
            (title: 'Home', keywords: 'all sessions', icon: Icons.grid_view_outlined,
              shortcut: null, run: _showHome),
            (title: 'Archived sessions', keywords: 'archive chats tasks restore unarchive',
              icon: Icons.archive_outlined, shortcut: null,
              run: () => unawaited(_settings(page: 'archived'))),
            (title: 'Open project', keywords: 'add folder directory', icon: Icons.create_new_folder_outlined,
              shortcut: null, run: () => unawaited(_addProject())),
            (title: 'Settings', keywords: 'preferences appearance accounts interface', icon: Icons.settings_outlined,
              shortcut: mac ? '⌘ ,' : null, run: () => unawaited(_settings())),
            if (_canOpenTerminal)
              (title: 'Toggle terminal', keywords: 'shell console', icon: Icons.terminal_outlined,
                shortcut: mac ? '⌘ J' : 'Ctrl J', run: _toggleTerminal),
              (title: 'Toggle sidebar', keywords: 'show hide navigation', icon: Icons.view_sidebar_outlined,
                shortcut: mac ? '⌘ B' : 'Ctrl B',
                run: () => unawaited(_run(() => _sidebar.chooseSidebarOpen(!_sidebar.sidebarOpen)))),
            if (task != null && !_homeOpen) ...[
              (title: 'Open browser', keywords: 'web url page preview', icon: Icons.language_rounded,
                shortcut: mac ? '⌘ ⇧ J' : 'Ctrl Shift J', run: _toggleBrowserPanel),
              (title: 'Toggle side panel', keywords: 'context files changes', icon: Icons.vertical_split_outlined,
                shortcut: mac ? '⌘ ⌥ B' : 'Ctrl Alt B', run: _toggleSidePanel),
              if (session.connected && !task.archiving)
                (title: task.archived ? 'Unarchive current session' : 'Archive current session',
                  keywords: 'archive restore task', icon: task.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
                  shortcut: null, run: () => unawaited(_run(() => session.setArchived(task, !task.archived)))),
            ],
          ],
          onOpen: (project, task) => unawaited(_run(() async {
            await _selectProject(project, task);
            if (mounted && !task.archived) _focusComposer();
          })),
        ),
      );
    } finally {
      _commandMenuOpen = false;
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

  Widget _accountCard(Json provider) {
    final id = provider['id'] as String;
    final name = provider['auth'] == 'opencode' ? 'OpenCode' : provider['name'] as String;
    final status = provider['status'] as String;
    final connected = {'signed_in', 'refresh_required'}.contains(status);
    final working = session.signingIn && session.loginProvider == id;
    final available = session.connected && !session.signingIn && session.signingOut == null;
    final buttonStyle = ButtonStyle(
      visualDensity: VisualDensity.standard,
      minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: desktopFontFamily, fontSize: 13, height: 16 / 13)),
      shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))));
    return Container(
      key: ValueKey('account:$id'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: desktopSidebar, border: Border.all(color: const Color(0x14000000), width: .5), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w500, color: desktopForeground)),
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
            TextButton(style: buttonStyle, onPressed: session.loginUrl == null ? null : session.openLoginBrowser, child: const Text('Open browser')),
            TextButton(style: buttonStyle, onPressed: () => _run(session.cancelLogin), child: const Text('Cancel')),
          ]),
        ] else
          Wrap(spacing: 8, children: [
            if (!connected)
              FilledButton(style: buttonStyle, onPressed: available ? () => _run(() => _signIn(id)) : null, child: Text('Sign in to $name'))
            else
              OutlinedButton(style: buttonStyle, onPressed: available ? () => session.signOut(id) : null, child: Text(session.signingOut == id ? 'Signing out…' : 'Sign out')),
            if (connected)
              TextButton(style: buttonStyle, onPressed: available ? () => _run(() => _signIn(id)) : null, child: const Text('Switch account')),
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
    if (_picking || !mounted) return;
    setState(() => _picking = true);
    try {
      if (!session.client.sharedFilesystem) {
        final input = TextEditingController(text: '~/workspace');
        String? path;
        try {
          path = await showDialog<String>(context: context, builder: (context) => AlertDialog(
            title: const Text('Open remote project'),
            content: SizedBox(width: 440, child: TextField(controller: input, autofocus: true,
              decoration: const InputDecoration(labelText: 'Folder on the remote machine'),
              onSubmitted: (value) => Navigator.pop(context, value.trim()))),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, input.text.trim()), child: const Text('Open'))]));
        } finally { input.dispose(); }
        if (path != null && path.isNotEmpty && mounted) {
          await session.addProject(path);
          if (mounted) { setState(() => session.viewingConversation = true); if (!_settingsOpen) _focusComposer(); }
        }
        return;
      }
      final paths = await MacosFilePicker().pick(
        MacosFilePickerMode.folder,
        allowsMultiple: false,
        dialogTitle: 'Open project',
      );
      try {
        if (mounted && paths != null && paths.isNotEmpty) {
          await session.addProject(paths.first.path);
          if (!mounted) return;
          setState(() => session.viewingConversation = true);
          if (!_settingsOpen) _focusComposer();
        }
      } finally {
        for (final path in paths ?? <MacosFilePickerPath>[]) {
          await path.release();
        }
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  });

  Future<void> _removeProject(Project project) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${project.name}?'),
        content: const Text('Remove this project and all its threads from Happen. Running threads will be stopped. The folder and saved thread history will be kept.'),
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
    session.removeListener(_rememberNavigation);
    session.addListener(_rememberNavigation);
    _rememberNavigation();
  }

  void _rememberNavigation() {
    final location = _homeOpen ? 'home' : session.sidebarId(session.draftKey);
    if (_navigationIndex >= 0 && _navigationHistory[_navigationIndex] == location) return;
    _navigationHistory.removeRange(_navigationIndex + 1, _navigationHistory.length);
    _navigationHistory.add(location);
    _navigationIndex = _navigationHistory.length - 1;
  }

  void _navigateHistory(int offset) {
    for (var index = _navigationIndex + offset; index >= 0 && index < _navigationHistory.length; index += offset) {
      final id = _navigationHistory[index];
      final draft = [for (final source in _sources) for (final draft in source.sessionDrafts)
        if (source.sidebarId(draft.id) == id) draft].firstOrNull;
      final thread = [for (final source in _sources) for (final project in source.projects.where((project) => !project.removing))
        for (final task in project.tasks) if (source.sidebarId(task.id) == id && !task.archived) (project, task)].firstOrNull;
      if (id != 'home' && draft == null && thread == null) continue;
      _navigationIndex = index;
      if (id == 'home') { _showHome(); }
      else if (draft != null) { _activateDraft(draft); }
      else { _openTask(thread!.$1, thread.$2); }
      return;
    }
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
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    if (!(mac ? keyboard.isMetaPressed : keyboard.isControlPressed) && !keyboard.isAltPressed) return KeyEventResult.ignored;
    if (const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true).accepts(event, keyboard)) {
      _selectAdjacentTask(-1);
      return KeyEventResult.handled;
    }
    if (const SingleActivator(LogicalKeyboardKey.arrowDown, alt: true).accepts(event, keyboard)) {
      _selectAdjacentTask(1);
      return KeyEventResult.handled;
    }
    SingleActivator shortcut(LogicalKeyboardKey key, {bool shift = false, bool alt = false}) =>
      SingleActivator(key, meta: mac, control: !mac, shift: shift, alt: alt);
    final task = _homeOpen ? null : session.task;
    final panels = task == null ? null : session.panelLayouts[task.id];
    final terminalFocused = terminalHasFocus;
    final bindings = <ShortcutActivator, VoidCallback>{
      shortcut(LogicalKeyboardKey.keyB): () => unawaited(_run(() => _sidebar.chooseSidebarOpen(!_sidebar.sidebarOpen))),
      shortcut(LogicalKeyboardKey.keyJ): _toggleTerminal,
      shortcut(LogicalKeyboardKey.keyB, alt: true): _toggleSidePanel,
      shortcut(LogicalKeyboardKey.keyJ, shift: true): _toggleBrowserPanel,
      shortcut(LogicalKeyboardKey.comma): () => unawaited(_settings()),
      shortcut(LogicalKeyboardKey.bracketLeft, shift: true): () => _selectAdjacentTask(-1),
      shortcut(LogicalKeyboardKey.bracketRight, shift: true): () => _selectAdjacentTask(1),
      for (final (index, key) in [
        LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4, LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit6,
        LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit8, LogicalKeyboardKey.digit9,
      ].indexed)
        shortcut(key): () => _selectThreadAt(index),
      if (terminalFocused) ...{
        shortcut(LogicalKeyboardKey.keyN): () {
          if (_terminalScope case final scope?) session.terminals.newShell(scope);
        },
        shortcut(LogicalKeyboardKey.keyW): _closeTerminal,
      } else ...{
        shortcut(LogicalKeyboardKey.bracketLeft): () => _navigateHistory(-1),
        shortcut(LogicalKeyboardKey.bracketRight): () => _navigateHistory(1),
        shortcut(LogicalKeyboardKey.keyK): () => unawaited(_commandMenu()),
        shortcut(LogicalKeyboardKey.keyN): () => unawaited(_run(_newChat)),
        shortcut(LogicalKeyboardKey.keyN, shift: true): () => unawaited(_run(_newChat)),
        shortcut(LogicalKeyboardKey.keyO, shift: true): () => unawaited(_run(_newChat)),
        shortcut(LogicalKeyboardKey.keyM, shift: true): () => _openComposerMenu(),
        shortcut(LogicalKeyboardKey.keyE, shift: true): () => _openComposerMenu(effort: true),
        if (!_homeOpen && task == null && session.currentDraft.submission == null && !_picking && !session.submitting)
          shortcut(LogicalKeyboardKey.keyP): _projectMenu.open,
        shortcut(LogicalKeyboardKey.keyW): () {
          if (task != null && panels?.opened == true && panels?.active != null) {
            session.closeSessionPanel(task, panels!.active!);
            if (!panels.opened) _focusComposer();
          }
        },
        if (task != null) ...{
          if (panels?.opened == true)
            shortcut(LogicalKeyboardKey.keyT): () => session.newSessionPanelTab(task),
          shortcut(LogicalKeyboardKey.keyP, shift: true): () =>
            unawaited(_run(() => session.pinTask(task, !session.pinnedTaskIds.contains(task.id)))),
        },
      },
      if (task != null && panels?.closed.isNotEmpty == true)
        shortcut(LogicalKeyboardKey.keyT, shift: true): () => session.openSessionPanel(task, panels!.closed.first),
    };
    for (final binding in bindings.entries) {
      if (!binding.key.accepts(event, keyboard)) continue;
      if (event is KeyDownEvent) binding.value();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _selectAdjacentTask(int offset) {
    final ids = sidebarThreadIds(session, projectKey: _sidebarProjectKey, sources: _sources);
    final index = _homeOpen ? -1 : ids.indexOf(session.sidebarId(session.draftKey));
    final next = index < 0 ? (offset > 0 ? 0 : ids.length - 1) : index + offset;
    if (next >= 0 && next < ids.length) _selectThread(ids[next]);
  }

  void _selectThreadAt(int index) {
    final ids = sidebarThreadIds(session, projectKey: _sidebarProjectKey, sources: _sources);
    if (index < 0 || index >= ids.length) return;
    _selectThread(ids[index]);
  }

  void _selectThread(String id) {
    final draft = [for (final source in _sources) for (final draft in source.sessionDrafts)
      if (source.sidebarId(draft.id) == id) draft].firstOrNull;
    if (draft != null) { _activateDraft(draft); }
    else {
      for (final source in _sources) for (final project in source.projects) {
        final task = project.tasks.where((task) => source.sidebarId(task.id) == id).firstOrNull;
        if (task != null) {
          _openTask(project, task);
          _focusComposer();
          return;
        }
      }
    }
  }

  void _openComposerMenu({bool effort = false}) {
    final composer = FocusManager.instance.primaryFocus?.context?.findAncestorStateOfType<_ComposerState>() ??
      _composer.currentState;
    if (composer == null) return;
    final menu = (effort ? composer._effortMenu.currentState : null) ?? composer._modelMenu.currentState;
    if (menu?.widget.enabled == true) menu!.showButtonMenu();
  }

  Future<void> _selectProject(Project project, [DesktopTask? task]) {
    final source = _source(project);
    widget.machines?.activate(source);
    return source.select(project, task);
  }

  Future<void> _newChat([Project? owner]) async {
    if (owner == null) {
      await _commandMenu(pickProject: true);
      return;
    }
    final source = _source(owner);
    if (owner.removing || !owner.available) return;
    widget.machines?.activate(source);
    source.newSession(owner);
    if (mounted) _focusComposer();
  }

  void _showHome() {
    session.showHome();
    unawaited(_run(session.refreshSessions));
  }

  void _openTask(Project project, DesktopTask task) {
    unawaited(_run(() => _selectProject(project, task)));
  }

  void _openDraft(Project project) {
    unawaited(_run(() async {
      await _selectProject(project);
      if (mounted) _focusComposer();
    }));
  }

  void _activateDraft(SessionDraft draft) {
    final source = _sources.firstWhere((source) => source.sessionDrafts.contains(draft));
    widget.machines?.activate(source);
    source.openDraft(draft);
    _focusComposer();
  }

  void _focusComposer() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_homeOpen) _composer.currentState?._focus.requestFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool get _canOpenTerminal => session.connected && session.project?.available == true && session.project?.removing != true &&
      session.task?.archived != true && session.task?.archiving != true;

  (String, String?)? get _terminalScope => _canOpenTerminal ? (session.project!.checkoutKey, session.draftKey) : null;

  void _openTerminal() {
    final project = session.project;
    if (!_canOpenTerminal || project == null) return;
    if (_homeOpen) setState(() => session.viewingConversation = true);
    session.terminals.open(_terminalScope!, project.path);
  }

  void _toggleTerminal() {
    final scope = _terminalScope;
    if (scope == null) return;
    if (session.terminals.groups[scope]?.visible == true) {
      session.terminals.hide(scope);
      _focusComposer();
    } else {
      _openTerminal();
    }
  }

  void _closeTerminal() {
    final scope = _terminalScope;
    final shell = session.terminals.groups[scope]?.active;
    if (scope == null || shell == null) return;
    session.terminals.closeShell(scope, shell);
    if (session.terminals.groups[scope]?.visible != true) _focusComposer();
  }

  void _toggleBrowserPanel() {
    final task = _homeOpen ? null : session.task;
    if (task == null) return;
    final tab = session.panelsFor(task).tabs.where(isBrowserPanel).firstOrNull;
    if (tab == null) { session.openBrowserPanel(task); }
    else { session.openSessionPanel(task, tab, toggle: true); }
    if (!session.panelsFor(task).opened) _focusComposer();
  }

  void _toggleSidePanel() {
    if (session.task case final task?) {
      session.toggleSidePanel(task);
      if (!session.panelsFor(task).opened) _composer.currentState?._focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) => DesktopToastListener(notices: session.notices, child: FocusScope(
    autofocus: true,
    child: Scaffold(
      body: LayoutBuilder(builder: (context, constraints) => ListenableBuilder(
        listenable: _viewChanges,
        builder: (context, _) => _workspace(context, constraints),
      )),
    ),
  ));

  Widget _workspace(BuildContext context, BoxConstraints constraints) {
    final tasks = session.projects.expand((project) => project.tasks).toSet();
    final minSidebarWidth = 280.0;
    final maxSidebarWidth = (constraints.maxWidth - 488).clamp(minSidebarWidth, 640.0);
    final savedWidth = _sidebar.sidebarWidth;
    final sidebarWidth = (_dragSidebarWidth ?? savedWidth).clamp(minSidebarWidth, maxSidebarWidth);
    final pane = _conversationPane(context, tasks);
    return ListenableBuilder(listenable: Listenable.merge([_sidebar, _sidebar.sidebarChanges, widget.machines]), child: pane,
      builder: (context, pane) => ColoredBox(color: desktopSidebar, child: DesktopSidebarFrame(
      open: _sidebar.sidebarOpen, width: sidebarWidth,
      resizerOffset: 4, resizing: _dragSidebarWidth != null,
      collapsedInset: _trafficInset == 0 ? 18 : _trafficInset,
      onToggle: () => unawaited(_run(() => _sidebar.chooseSidebarOpen(!_sidebar.sidebarOpen))),
      unread: _sources.any((source) => source.projects.where((project) => !project.removing).expand((project) => project.tasks)
        .any((task) => source.hasUnseenCompletion(task) || !task.archived && task.questions.isNotEmpty) ||
        source.sideChats.values.any((task) => !task.archived && !task.archiving &&
          (task.questions.isNotEmpty || source.hasUnseenCompletion(task)))),
      sidebar: ThreadSidebar(session: session, home: _homeOpen, windowControls: _trafficInset > 0,
            sources: _sources,
            machinePicker: widget.machinePicker ?? (widget.machines == null ? null : MachinePicker(machines: widget.machines!,
              onSettings: () => unawaited(_settings(page: 'servers')))),
            titlebarInset: _trafficInset, projectKey: _sidebarProjectKey,
            onProjectFilter: (key) => setState(() => _sidebarProjectKey = key),
            onBack: _navigationIndex > 0 ? () => _navigateHistory(-1) : null,
            onForward: _navigationIndex < _navigationHistory.length - 1 ? () => _navigateHistory(1) : null,
            onHome: _showHome, onSearch: () => unawaited(_commandMenu()),
            onNew: () => unawaited(_run(_newChat)), onSettings: _settings,
            onProjectSettings: (project) { widget.machines?.activate(_source(project)); unawaited(_settings(project: project)); },
            onAddProject: () => unawaited(_addProject()),
            onRefresh: () => unawaited(_run(widget.machines?.refreshCatalogs ?? session.refreshProjects)),
            onSelect: _openTask, onDraft: _activateDraft,
            onArchive: (task, archived) => unawaited(_run(() => _taskSource(task).setArchived(task, archived))))
        ,
      resizer: _sidebarResizer(sidebarWidth, minSidebarWidth, maxSidebarWidth),
      child: pane!,
    )));
  }

  Widget _sidebarResizer(double sidebarWidth, double minSidebarWidth, double maxSidebarWidth) =>
    SidebarResizer(key: const ValueKey('sidebar-resizer'), size: sidebarWidth,
      min: minSidebarWidth, max: maxSidebarWidth,
      onResize: (width) => setState(() => _dragSidebarWidth = width),
      onResizeEnd: (width) {
        unawaited(_run(() => _sidebar.chooseSidebarWidth(width)));
        setState(() => _dragSidebarWidth = null);
      },
      onCancel: () => setState(() => _dragSidebarWidth = null));

  Widget _conversationPane(BuildContext context, Set<DesktopTask> tasks) {
    final home = _homeOpen;
    final transcript = home ? null : session.task ?? session.currentDraft.submission;
    return TerminalWorkspace(key: _conversationPaneKey, controller: session.terminals, scope: home ? null : _terminalScope,
      child: SessionPanelWorkspace(
            session: session, task: home ? null : session.task,
            sideComposer: (side, active) => _Composer(key: ValueKey('composer:${side.draftKey}'),
              session: session, target: side, active: active),
            onReturnFocus: () => _composer.currentState?._focus.requestFocus(),
            child: Material(color: desktopCanvas, child: Stack(fit: StackFit.expand, children: [
              if (!home) ProjectDetailsWorkspace(session: session,
                header: (opened, toggle) => _header(context, opened, toggle),
                child: Column(children: [
                if (transcript == null)
                  Expanded(child: NewSessionScreen(session: session, picking: _picking,
                    machinePicker: widget.machines == null ? null : ThreadMachinePicker(machines: widget.machines!, session: session),
                    projectMenuController: _projectMenu,
                    onSelect: _openDraft, onAddProject: () => unawaited(_addProject()),
                    onRemoveProject: (project) => unawaited(_run(() => _removeProject(project))),
                    onReturnFocus: _focusComposer,
                    onOpenFolder: session.client.sharedFilesystem && session.project?.available == true
                      ? () => unawaited(_run(() => session.openProjectFolder(session.project!))) : null,
                    composer: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (session.project?.available == true)
                        McpConversationAuth(key: ValueKey((session.client, session.project!.path)),
                          client: session.client, cwd: session.project!.path),
                      _Composer(key: _composer, session: session),
                    ])))
                else ...[
                  Expanded(child: ConversationDataScope(client: session.client, providers: session.providers, child: ConversationDeck(
                      task: transcript,
                      tasks: tasks,
                      directory: session.project?.path ?? '',
                      empty: const SizedBox.shrink(),
                      onRetry: (task) => unawaited(_run(() => session.loadHistory(task))),
                      onRetryTurn: (task) => unawaited(_run(() => session.retry(task))),
                      onLoadEarlier: (task) => unawaited(_run(() => session.loadEarlier(task))),
                      onPendingAction: (task, inboxID, action) => _run(() => session.changePending(task, inboxID, action)),
                      onFork: session.connected && session.project?.available == true && session.project?.removing != true
                        ? (task, turnId) => _run(() => session.forkFromResponse(task, turnId)) : null,
                  ))),
                  if (session.project != null && session.project!.available && session.task?.archived != true)
                    McpConversationAuth(key: ValueKey((session.client, session.project!.path)),
                      client: session.client, cwd: session.project!.path),
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
                        onPressed: () => _run(() => session.setArchived(session.task!, false)),
                        icon: const Icon(Icons.unarchive_outlined),
                        label: const Text('Restore task to continue'),
                      ),
                    )
                  else if (session.project != null)
                    _Composer(key: _composer, session: session),
                ],
              ])),
               if (home) WorkspaceHome(session: session, focusNode: _sessionSearchFocus,
                 sources: _sources,
                 onProjectSettings: (project) { widget.machines?.activate(_source(project)); unawaited(_settings(project: project)); },
                onSelect: _openTask, onNew: (project) => unawaited(_run(() => _newChat(project))),
                onArchive: (task, archived) => unawaited(_run(() => _taskSource(task).setArchived(task, archived))),
                onAddProject: () => unawaited(_addProject())),
            ])),
           ),
    );
  }

  Widget _header(BuildContext context, bool detailsOpen, VoidCallback toggleDetails) => DesktopWindowDragRegion(child: AnimatedPadding(
    duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
    padding: EdgeInsets.only(left: !_sidebar.sidebarOpen ? (_trafficInset == 0 ? 50 : _trafficInset + 40) : 16, right: 12),
    child: SizedBox(height: 56, child: Row(
      children: [
        if (widget.machines != null) Padding(padding: const EdgeInsets.only(right: 16), child: SizedBox(width: 156, child: Row(children: [
          Icon(session.client.sharedFilesystem ? Icons.computer_outlined : Icons.dns_outlined, size: 14, color: desktopSecondary),
          const SizedBox(width: 6), Expanded(child: Text(widget.machines!.machineFor(session).name,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: desktopSecondary))),
        ]))),
        Expanded(child: LayoutBuilder(builder: (context, bounds) => Row(children: [
          if (session.project != null) ...[
            ProjectAvatar(project: session.project!, size: 14, generated: session.projectAvatarStyle == 'generated'),
            const SizedBox(width: 7),
            ConstrainedBox(constraints: BoxConstraints(maxWidth: bounds.maxWidth * .4),
              child: Text(session.project!.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: desktopSecondary))),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text('/', style: TextStyle(color: Color(0xffc8cacf)))),
          ],
          Expanded(child: Text(
            session.task?.title ?? 'New thread',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w500,
              letterSpacing: -.04,
              fontVariations: const [FontVariation('wght', 530)],
              color: desktopForeground),
          )),
        ]))),
        if (session.task != null)
          ContextUsageIndicator(messages: session.task!.messages.values,
            limit: session.task!.contextLimit ?? session.modelInfo?['context_limit'] as num?,
            onPressed: () {
              session.openSessionPanel(session.task!, contextPanel, toggle: true);
              if (!session.panelsFor(session.task!).opened) _composer.currentState?._focus.requestFocus();
            }),
        if (session.project != null) ...[
          WorkspacePanelButton(key: const ValueKey('toggle-project-details'),
            tooltip: 'Toggle project details', opened: detailsOpen,
            onPressed: session.project!.available && !session.project!.removing ? toggleDetails : null,
            icon: const Icon(Icons.article_outlined, size: 18)),
          const SizedBox(width: 4),
          ListenableBuilder(listenable: session.terminals, builder: (context, _) => WorkspacePanelButton(
            tooltip: 'Toggle terminal (${defaultTargetPlatform == TargetPlatform.macOS ? '⌘J' : 'Ctrl+J'})',
            opened: session.terminals.groups[_terminalScope]?.visible == true,
            onPressed: _canOpenTerminal ? _toggleTerminal : null,
            icon: const BottomPanelIcon())),
          const SizedBox(width: 4),
          WorkspacePanelButton(key: const ValueKey('toggle-side-panel'),
            tooltip: 'Toggle side panel (${defaultTargetPlatform == TargetPlatform.macOS ? '⌘⌥B' : 'Ctrl+Alt+B'})',
            opened: session.task != null && session.panelLayouts[session.task!.id]?.opened == true,
            onPressed: session.task == null ? null : _toggleSidePanel,
            icon: SidePanelIcon(opened: session.task != null && session.panelLayouts[session.task!.id]?.opened == true)),
        ],
      ],
    )),
  ));
}

class _Composer extends StatefulWidget {
  const _Composer({super.key, required this.session, this.target, this.active = true});
  final DesktopSession session;
  final DesktopTask? target;
  final bool active;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  DesktopTask? get _target => widget.target ?? widget.session.task;
  Project? get _project => widget.target == null ? widget.session.project
    : widget.session.projects.where((project) =>
        project.tasks.any((task) => task.id == widget.target!.sideParentID)).firstOrNull;
  String get _currentDraftKey => widget.target?.draftKey ?? widget.session.draftKey;
  bool get _submitting => widget.target?.sideSubmitting ?? widget.session.submitting;
  String? get _attachmentStatus => widget.target == null
    ? widget.session.attachmentStatus : widget.target!.sideAttachmentStatus;
  void _saveDrafts() { if (widget.target == null) widget.session.saveDrafts(); }
  void _showError(Object error) => widget.session.showError(error, target: widget.target);
  late String _draftKey = _currentDraftKey;
  late ComposerTextController _text = ComposerTextController(
    text: widget.session.drafts[_draftKey] ?? '',
    selection: widget.session.draftSelections[_draftKey],
    files: widget.session.fileDrafts[_draftKey] ?? const [],
  );
  final _focus = FocusNode();
  final _autocomplete = GlobalKey<ComposerAutocompleteState>();
  late final _modelMenu = GlobalKey<PopupMenuButtonState<String>>();
  late final _effortMenu = GlobalKey<PopupMenuButtonState<String>>();
  var _attachmentLifetime = CancellationToken();
  bool _receivingAttachments = false, _draggingAttachments = false;
  List<ComposerAttachment> get _attachments => _submitting ? const []
    : widget.session.attachmentDrafts[_draftKey] ?? const [];
  late Object _voiceOwner = Object();
  DictationService? _boundVoice;
  ComposerDictationSession? _voiceText;
  FocusNode? _voiceFocus;
  bool _answerVoice = false, _finishingVoice = false, _disposing = false;
  DictationService get _voice => widget.session.dictation;
  bool get _ownsVoice => identical(_voice.owner, _voiceOwner);
  bool get _dictating => _ownsVoice && (_voice.active || _finishingVoice);
  DictationUiPhase get _voicePhase => !_ownsVoice ? DictationUiPhase.idle : switch (_voice.state) {
    DictationIdle() => _finishingVoice ? DictationUiPhase.transcribing : DictationUiPhase.idle,
    DictationStarting() => DictationUiPhase.starting,
    DictationRecording() => DictationUiPhase.recording,
    DictationTranscribing() => DictationUiPhase.transcribing,
    DictationFailed(:final canRetry) => canRetry ? DictationUiPhase.retry : DictationUiPhase.idle,
    DictationDisposed() => DictationUiPhase.idle,
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

  Future<void> _startVoice({QuestionComposer? answer}) async {
    if (_voice.active || _finishingVoice || !widget.session.connected || _submitting || answer?.enabled == false) return;
    final controller = answer?.controller ?? _text;
    final focus = answer?.focus ?? _focus;
    _voiceOwner = Object();
    _voiceFocus = focus;
    _answerVoice = answer != null;
    _voiceText?.dispose();
    _voiceText = ComposerDictationSession(controller, (range, text) {
      final editorContext = focus.context;
      if (!_disposing && editorContext != null && editorContext.mounted) {
        Actions.invoke(editorContext, ReplaceTextIntent(controller.value, text, range, SelectionChangedCause.keyboard));
      } else {
        // Navigation may already have detached the editable widget. Restore the
        // saved draft through its controller without looking up widget actions.
        controller.value = TextEditingValue(text: controller.text.replaceRange(range.start, range.end, text),
          selection: TextSelection.collapsed(offset: range.start + text.length));
      }
    });
    if (widget.active) focus.requestFocus();
    await _voice.start(owner: _voiceOwner, liveTranscription: widget.session.dictationMode == 'live',
      onRecordingLimit: () => unawaited(_finishVoice(DictationAction.insert)));
  }

  Future<void> _cancelVoice({bool restoreFocus = true}) async {
    if (!_ownsVoice) return;
    final focus = _voiceFocus ?? _focus;
    _voiceText?.dispose(cancel: true);
    _voiceText = null;
    final cancellation = _voice.cancel();
    _voiceOwner = Object();
    _voiceFocus = null;
    _answerVoice = false;
    _finishingVoice = false;
    await cancellation;
    if (mounted && widget.active && restoreFocus && focus.context?.mounted == true) focus.requestFocus();
  }

  void _cancelAnswerVoice() {
    if (_answerVoice) unawaited(_cancelVoice(restoreFocus: false));
  }

  void _advanceAnswer(VoidCallback advance) {
    if (_answerVoice && _dictating) {
      unawaited(_finishVoice(DictationAction.send, onSend: advance));
    } else { advance(); }
  }

  Future<void> _finishVoice(DictationAction action, {bool retry = false, VoidCallback? onSend}) async {
    if (!_ownsVoice || _finishingVoice) return;
    final owner = _voiceOwner;
    final focus = _voiceFocus ?? _focus;
    if (retry && widget.active) focus.requestFocus();
    setState(() => _finishingVoice = true);
    try {
      final result = retry ? await _voice.retry(action) : await _voice.stop(action);
      if (!mounted || !identical(_voiceOwner, owner) || !_ownsVoice || result == null) return;
      final inserted = await _voiceText?.finish(result.text) ?? false;
      if (!mounted || !identical(_voiceOwner, owner) || !_ownsVoice || !inserted) return;
      _voiceText?.dispose();
      _voiceText = null;
      if (widget.active) focus.requestFocus();
      if (result.action == DictationAction.send) {
        if (onSend != null) { onSend(); } else { await _sendPrompt(); }
      }
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
    if (widget.active) _focus.requestFocus();
  }

  @override
  void didUpdateWidget(_Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _focus.requestFocus();
    if (identical(oldWidget.session, widget.session) && _draftKey == _currentDraftKey) return;
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
    _voiceFocus = null;
    _answerVoice = false;
    _finishingVoice = false;
    final previous = _text;
    previous.removeListener(_saveDraft);
    _draftKey = _currentDraftKey;
    _text = ComposerTextController(
      text: widget.session.drafts[_draftKey] ?? '',
      selection: widget.session.draftSelections[_draftKey],
      files: widget.session.fileDrafts[_draftKey] ?? const [],
    )..addListener(_saveDraft);
    // The editor and autocomplete detach their listeners during this build.
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  void _saveDraft() {
    widget.session.draftSelections[_draftKey] = _text.selection;
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
    _saveDrafts();
  }

  Future<void> _copy({bool cut = false, TextEditingController? controller, FocusNode? focus}) async {
    controller ??= _text;
    final before = controller.value, selection = controller.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    final text = controller is ComposerTextController
      ? controller.serializeRange(selection.start, selection.end)
      : controller.text.substring(selection.start, selection.end);
    await Clipboard.setData(ClipboardData(text: text));
    if (cut && mounted && controller.value == before && !_submitting) {
      final editor = (focus ?? _focus).context;
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
    _saveDrafts();
    _focus.requestFocus();
  }

  Future<void> _paste(SelectionChangedCause cause, {TextEditingController? controller, FocusNode? focus}) async {
    if (_receivingAttachments || _submitting || _dictating || !widget.session.connected) return;
    if (controller != null) {
      final before = controller.value, lifetime = _attachmentLifetime;
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || lifetime.isCancelled || controller.value != before || data?.text == null) return;
      final range = before.selection.isValid ? before.selection : TextSelection.collapsed(offset: before.text.length);
      final editor = focus?.context;
      if (editor != null && editor.mounted) Actions.invoke(editor, ReplaceTextIntent(before, data!.text!, range, cause));
      return;
    }
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
      if (mounted && !lifetime.isCancelled) _showError(error);
    } finally {
      if (mounted && identical(_attachmentLifetime, lifetime)) setState(() => _receivingAttachments = false);
    }
  }

  Future<void> _drop(DropDetails details) async {
    if (_receivingAttachments || _submitting) return;
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
      if (mounted && !lifetime.isCancelled) _showError(error);
    } finally {
      if (mounted && identical(_attachmentLifetime, lifetime)) setState(() => _receivingAttachments = false);
    }
  }

  Future<void> _pickAttachments() async {
    if (_receivingAttachments || _submitting || _dictating) return;
    final lifetime = _attachmentLifetime;
    setState(() => _receivingAttachments = true);
    try {
      final paths = await MacosFilePicker().pick(MacosFilePickerMode.file,
        allowsMultiple: true, initialDirectory: _project?.path, dialogTitle: 'Attach files');
      try {
        lifetime.throwIfCancelled();
        if (mounted) _addAttachments([for (final path in paths ?? <MacosFilePickerPath>[]) composerAttachmentForFile(path.path)]);
      } finally {
        for (final path in paths ?? <MacosFilePickerPath>[]) { await path.release(); }
      }
    } on CancelledException {
      // A different task now owns the composer.
    } catch (error) {
      if (mounted && !lifetime.isCancelled) _showError(error);
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
    if (_receivingAttachments || _submitting) return;
    if (_autocomplete.currentState?.consumeCommand() == true) return;
    final controller = _text, draftKey = _draftKey;
    final value = controller.value;
    final files = controller.files;
    final draft = _text.text;
    final prompt = _text.serializePrompt();
    final attachments = List<ComposerAttachment>.of(_attachments);
    final annotations = widget.session.annotationsFor(draftKey);
    void restore() {
      if (mounted && identical(_text, controller) && _text.text.isEmpty) {
        controller.value = value;
        controller.restoreFiles(0, files);
      }
    }
    try {
      final submission = widget.session.send(prompt, attachments: attachments, annotations: annotations, target: widget.target);
      if (_submitting) {
        _autocomplete.currentState?.dismiss();
        // Keep the saved draft until acknowledgement so a failed send can be
        // restored even after switching sessions or closing the application.
        controller.removeListener(_saveDraft);
        controller.clear();
        controller.addListener(_saveDraft);
      }
      final accepted = await submission;
      if (accepted) {
        if (mounted && identical(_text, controller)) _autocomplete.currentState?.dismiss();
        if (widget.session.drafts[draftKey] == draft) {
          widget.session.drafts.remove(draftKey);
          widget.session.draftSelections.remove(draftKey);
          widget.session.fileDrafts.remove(draftKey);
        }
        final ids = attachments.map((attachment) => attachment.id).toSet();
        widget.session.attachmentDrafts[draftKey]?.removeWhere((attachment) => ids.contains(attachment.id));
        if (widget.session.attachmentDrafts[draftKey]?.isEmpty == true) widget.session.attachmentDrafts.remove(draftKey);
        for (final attachment in attachments) {
          if (attachment.image || !widget.session.client.sharedFilesystem) await attachment.discard();
        }
        if (mounted && identical(_text, controller) && _text.text == draft) _text.clear();
        _saveDrafts();
        if (mounted) setState(() {});
      } else { restore(); }
    } on CancelledException {
      // Application exit owns cancellation.
      restore();
    }
  }

  Future<void> _stop() async {
    try {
      await widget.session.stop(target: widget.target);
    } on CancelledException {
      // Application exit owns cancellation.
    } catch (error) {
      _showError(error);
    }
  }

  void _newline([TextEditingController? controller]) {
    controller ??= _text;
    final value = controller.value;
    if (!value.composing.isCollapsed) return;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    controller.value = TextEditingValue(
      text: value.text.replaceRange(selection.start, selection.end, '\n'),
      selection: TextSelection.collapsed(offset: selection.start + 1),
    );
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
    final target = _target, request = _target?.questions.values.firstOrNull;
    if (target != null && request != null && (!_dictating || _answerVoice)) {
      final id = request['id'] as String;
      return SessionQuestionDock(
        key: ValueKey('question:${target.id}:$id'), request: request,
        draft: target.questionDrafts.putIfAbsent(id, () => QuestionDraft.fromRequest(request)),
        directory: _project?.path ?? '',
        enabled: widget.session.connected && !_submitting,
        active: widget.active,
        onBeforeChange: _cancelAnswerVoice,
        onAdvance: _advanceAnswer,
        onAnswer: (answers, cancellation) => widget.session.answerQuestion(
          target, id, answers, cancellation: cancellation),
        composer: (answer) => _input(context, answer: answer),
      );
    }
    return _input(context);
  }

  Widget _input(BuildContext context, {QuestionComposer? answer}) {
    final session = widget.session;
    final newThread = answer == null && _target == null;
    final running = _target?.running == true;
    final hasProject = _project?.available == true && _project?.removing != true;
    final authenticated = session.authenticatedFor(widget.target);
    final available =
        hasProject &&
        session.connected &&
        !_receivingAttachments &&
        !_submitting &&
        !(newThread && session.pullingCheckout) &&
        _target?.sidePreparing != true &&
        _target?.archived != true && _target?.archiving != true &&
        _target?.loading != true &&
        _target?.loadError == null && (answer?.enabled ?? true);
    final controller = answer?.controller ?? _text;
    final focus = answer?.focus ?? _focus;
    Future<void> copy({bool cut = false}) => _copy(cut: cut, controller: controller, focus: focus);
    Future<void> paste(SelectionChangedCause cause) => _paste(cause,
      controller: answer?.controller, focus: focus);
    void submit() {
      if (!available) return;
      if (answer != null) { answer.advance(); } else { unawaited(_submit()); }
    }
    Widget autocomplete(Widget child) {
      if (answer != null) return child;
      return ComposerAutocomplete(
        key: _autocomplete,
        controller: _text,
        focusNode: _focus,
        client: session.client,
        cwd: _project?.path ?? '',
        provider: _target?.provider ?? session.providerId,
        enabled: hasProject && session.connected && !_submitting && !_dictating,
        session: session,
        target: widget.target,
        commands: {
          if (widget.target == null && _project != null)
            '/new': (description: 'Start a new session', run: () => session.newSession(_project!)),
          if (defaultTargetPlatform == TargetPlatform.macOS)
            '/attach': (description: 'Attach files and images', run: () => unawaited(_pickAttachments())),
          '/history': (description: 'Search previous prompts', run: () => _autocomplete.currentState?.openHistory()),
          if (session.task != null) '/context': (description: 'Inspect session context',
            run: () => session.openSessionPanel(session.task!, contextPanel)),
          if (session.task != null) '/browser': (description: 'Open the in-app browser',
            run: () => session.openBrowserPanel(session.task!)),
          if (widget.target == null && session.task != null)
            '/side': (description: 'Ask a side question in a temporary chat',
              run: () => unawaited(() async {
                try { await session.openSideChat(session.task!); }
                on CancelledException { /* The pending side chat was closed. */ }
                catch (error) { session.showError(error); }
              }())),
          if (session.connected && _project?.available == true && _project?.removing != true && session.task?.archived != true && session.task?.archiving != true)
            '/terminal': (description: 'Open the project terminal', run: () => session.terminals.open(
              (_project!.checkoutKey, session.draftKey), _project!.path)),
        },
        child: child,
      );
    }
    return ListenableBuilder(listenable: session.annotationChanges, builder: (context, _) => DropTarget(
      enabled: answer == null && hasProject && session.connected && !_submitting && !_receivingAttachments,
      acceptedKinds: const {DropItemKind.file, DropItemKind.directory},
      onDrop: _drop,
      onEnter: (_) => setState(() => _draggingAttachments = true),
      onLeave: () { if (mounted) setState(() => _draggingAttachments = false); },
      child: Center(
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: newThread ? desktopNewThreadComposerWidth : desktopConversationWidth + 40),
        child: Padding(
          padding: newThread ? EdgeInsets.zero : const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: answer == null ? double.infinity : MediaQuery.sizeOf(context).height * .65),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (answer != null) Flexible(fit: FlexFit.loose, child: answer.panel),
          CallbackShortcuts(
            bindings: {
              if (answer == null || _ownsVoice && (_dictating || _voice.state is DictationFailed))
              const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): () {
                if (!controller.value.composing.isCollapsed) return;
                if (_ownsVoice && (_dictating || _voice.state is DictationFailed)) unawaited(_cancelVoice());
              },
              const SingleActivator(LogicalKeyboardKey.enter, shift: true): () => _newline(controller),
              const SingleActivator(
                LogicalKeyboardKey.enter,
                includeRepeats: false,
              ): () {
                if (controller.value.composing.isCollapsed) submit();
              },
              const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
                if (controller.value.composing.isCollapsed) submit();
              },
              const SingleActivator(
                LogicalKeyboardKey.enter,
                control: true,
              ): () {
                if (controller.value.composing.isCollapsed) submit();
              },
            },
            child: Actions(actions: {CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
              onInvoke: (intent) { unawaited(copy(cut: intent.collapseSelection)); return null; }),
              PasteTextIntent: ComposerPasteAction(
              enabled: available && !_dictating, paste: paste)},
            child: autocomplete(DecoratedBox(
                key: const ValueKey('conversation-composer'),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _draggingAttachments ? Theme.of(context).colorScheme.primary
                    : desktopBorder,
                    width: _draggingAttachments ? 2 : 1),
                  boxShadow: const [
                    BoxShadow(color: Color(0x0a000000), blurRadius: 4, offset: Offset(0, 2)),
                    BoxShadow(color: Color(0x14000000), blurRadius: 2, spreadRadius: -1, offset: Offset(0, 1)),
                  ],
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(8, 0, 8, 0),
                  child: Column(
                    children: [
                      if (answer == null && !_submitting && session.annotationsFor(_draftKey).isNotEmpty)
                        ResponseAnnotationAttachments(annotations: session.annotationsFor(_draftKey),
                          onEdit: ConversationAnnotationScope.maybeOf(context)?.onEdit,
                          onRemove: (id) => session.removeAnnotation(_draftKey, id)),
                      if (_draggingAttachments) const Padding(padding: EdgeInsets.all(8), child: Text('Drop images or files to attach')),
                      if (answer == null && _attachments.isNotEmpty) Align(
                        alignment: Alignment.centerLeft,
                        child: AttachmentRail(composer: true, attachments: _attachments.map((attachment) => attachment.toJson()).toList(),
                          onRemove: _submitting ? null : (index) {
                            final removed = _attachments[index];
                            setState(() => widget.session.attachmentDrafts[_draftKey]!.remove(removed));
                            _saveDrafts();
                            unawaited(removed.discard());
                          }),
                      ),
                      if (_receivingAttachments || _attachmentStatus != null) Row(children: [
                        const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_attachmentStatus ?? 'Adding attachments…', style: const TextStyle(fontSize: 12))),
                        if (_attachmentStatus != null) IconButton(tooltip: 'Cancel upload',
                          onPressed: () => session.cancelUpload(target: widget.target), icon: const Icon(Icons.close, size: 16)),
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
                      ConstrainedBox(constraints: BoxConstraints(minHeight: newThread ? 72 : 56), child: ComposerEditor(
                        controller: controller,
                        focusNode: focus,
                        enabled: hasProject && session.connected && (answer?.enabled ?? true),
                        placeholder: answer?.placeholder ?? r'Ask anything, @ for files, $ for skills, / for commands',
                        label: answer == null ? 'Message' : 'Answer',
                        paste: paste, copy: copy,
                      )),
                      SizedBox(height: 40, child: Row(
                        children: [
                          if (answer == null)
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
                                mouseCursor: MouseCursor.defer,
                                leading: Icon(Icons.alternate_email_rounded, size: 16), title: Text('Add context'), trailing: Text('@'))),
                              const PopupMenuItem(value: 'commands', child: ListTile(dense: true, contentPadding: EdgeInsets.zero,
                                mouseCursor: MouseCursor.defer,
                                leading: Icon(Icons.terminal_rounded, size: 16), title: Text('Commands'), trailing: Text('/'))),
                              const PopupMenuItem(value: 'history', child: ListTile(dense: true, contentPadding: EdgeInsets.zero,
                                mouseCursor: MouseCursor.defer,
                                leading: Icon(Icons.history_rounded, size: 16), title: Text('Prompt history'), trailing: Text('⇧↑'))),
                              if (defaultTargetPlatform == TargetPlatform.macOS)
                                const PopupMenuItem(value: 'attach', child: ListTile(dense: true, contentPadding: EdgeInsets.zero,
                                  mouseCursor: MouseCursor.defer,
                                  leading: Icon(Icons.attach_file_rounded, size: 16), title: Text('Attach files'))),
                            ],
                            child: MouseRegion(cursor: available && !_dictating ? SystemMouseCursors.click : SystemMouseCursors.basic,
                              child: const SizedBox.square(dimension: 32,
                                child: Icon(Icons.add_rounded, size: 20, color: desktopSecondary)))),
                          if (_dictating) ...[
                            DictationCancelButton(onCancel: () => unawaited(_cancelVoice())),
                            const SizedBox(width: 8),
                          ],
                          if (defaultTargetPlatform == TargetPlatform.macOS) ...[
                            DictationButton(
                              phase: _voicePhase,
                              amplitude: _voice.amplitude,
                              enabled: available && (!_voice.active || _ownsVoice),
                              onStart: () => unawaited(_startVoice(answer: answer)),
                              onStop: () => unawaited(_finishVoice(DictationAction.insert)),
                              onCancel: () => unawaited(_cancelVoice()),
                              onRetry: () => unawaited(_finishVoice(DictationAction.insert, retry: true)),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Expanded(child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                            if (answer == null)
                              Flexible(child: ComposerModelPicker(session: session, enabled: available, target: widget.target,
                                modelMenuKey: _modelMenu, effortMenuKey: _effortMenu))
                            else if (!answer.sending)
                              const Flexible(child: Padding(padding: EdgeInsets.only(left: 16),
                                child: Text('↵ to continue · ⇧↵ for a new line', maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 11, color: desktopTertiary)))),
                          ])),
                          const SizedBox(width: 8),
                          if (answer?.previous case final previous?) ...[
                            TextButton(onPressed: previous,
                              style: TextButton.styleFrom(minimumSize: const Size(0, 32),
                                padding: const EdgeInsets.symmetric(horizontal: 10)),
                              child: const Text('Previous', style: TextStyle(fontSize: 12))),
                            const SizedBox(width: 6),
                          ],
                          if (answer != null)
                            FilledButton(onPressed: available && (_dictating
                                ? _voice.state is DictationRecording && !_finishingVoice : answer.canSubmit) ? submit : null,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(0, 32),
                                padding: const EdgeInsets.symmetric(horizontal: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                              child: answer.sending
                                ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.5))
                                : Text(answer.action, style: const TextStyle(fontSize: 12)))
                          else ValueListenableBuilder<TextEditingValue>(valueListenable: _text, builder: (context, value, _) {
                            final hasContent = value.text.trim().isNotEmpty || _attachments.isNotEmpty || session.annotationsFor(_draftKey).isNotEmpty;
                            final stopWorking = running && !hasContent && !_dictating;
                            final dictationCanSend = _dictating && _voice.state is DictationRecording && !_finishingVoice;
                            return IconButton.filled(
                            style: IconButton.styleFrom(
                              backgroundColor: desktopForeground, foregroundColor: desktopSurface,
                              disabledBackgroundColor: const Color(0xffececef), disabledForegroundColor: const Color(0xffb0b3b9),
                              minimumSize: const Size.square(32), maximumSize: const Size.square(32), padding: EdgeInsets.zero,
                              shape: const CircleBorder(),
                            ),
                            tooltip: _target?.sidePreparing == true ? 'Preparing side chat…'
                                : stopWorking ? 'Stop task and clear pending messages' : running
                                ? (session.deliveryMode == 'steer'
                                      ? 'Steer task'
                                      : 'Queue message')
                                : 'Send message',
                            onPressed: stopWorking ? (session.connected ? _stop : null) : available && authenticated &&
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
                      if (answer == null && !authenticated)
                        const Align(alignment: Alignment.centerLeft, child: Text('Sign in to the selected provider to send',
                          style: TextStyle(fontSize: 11, color: Colors.black38))),
                    ],
                  ),
                ),
              )),
            ),
          ),
          ])),
        ),
      ),
      ),
    ));
  }
}

String _authLabel(String status) => switch (status) {
  'signed_in' => 'Signed in',
  'refresh_required' => 'Login saved',
  'expired' => 'Login expired',
  'invalid' => 'Check login',
  _ => 'Not signed in',
};
