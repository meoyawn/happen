import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'appearance_settings.dart';
import 'pinned_sidebar_preferences.dart';
import 'shortcut_preferences.dart';
import 'project_avatar.dart';
import 'project_actions_state.dart';
import 'project_icon_picker.dart';
import 'project_icon_state.dart';
import 'project_script_dialog.dart';
import 'session.dart';
import 'machines.dart';
import 'remote_settings.dart';
import 'desktop_notifications.dart';
import 'notification_preferences.dart';
import 'window_chrome.dart';

const _pages = [
  (id: 'servers', label: 'Environments', icon: Icons.dns_outlined,
    description: 'Manage where your projects and threads run'),
  (id: 'providers', label: 'Providers', icon: Icons.key_outlined,
    description: 'Manage the accounts you use for AI models'),
  (id: 'preferences', label: 'Preferences', icon: Icons.tune,
    description: 'Customize preferences and default behavior'),
  (id: 'appearance', label: 'Appearance', icon: Icons.palette_outlined,
    description: 'Customize how Happen looks'),
  (id: 'shortcuts', label: 'Shortcuts', icon: Icons.keyboard_outlined,
    description: 'Choose keyboard shortcuts for Happen'),
  (id: 'projects', label: 'Projects', icon: Icons.folder_outlined,
    description: 'Manage your projects and customize their appearance'),
  (id: 'archived', label: 'Archived tasks', icon: Icons.archive_outlined,
    description: 'View past conversations or restore them to continue'),
];

// OpenCode: app/src/settings/{navigation.tsx,settings.css}; only supported pages are listed.
class DesktopSettingsScreen extends StatefulWidget {
  const DesktopSettingsScreen({super.key, required this.session, required this.accounts,
    required this.archived, required this.run, this.addProject, this.openProject,
    this.removeProject, this.windowControls = true, this.initialPage = 'preferences', this.initialProject, this.machines,
    this.shortcutError});
  final DesktopSession session;
  final MachinesController? machines;
  final Widget accounts, archived;
  final Future<void> Function(Future<void> Function()) run;
  final Future<void> Function()? addProject;
  final Future<void> Function(Project)? openProject, removeProject;
  final bool windowControls;
  final String initialPage;
  final Project? initialProject;
  final String? Function(SingleActivator)? shortcutError;

  @override
  State<DesktopSettingsScreen> createState() => _DesktopSettingsScreenState();
}

class _DesktopSettingsScreenState extends State<DesktopSettingsScreen> {
  List<DesktopSession> get _sources => widget.machines?.sessions.map((machine) => machine.session).toList() ?? [widget.session];
  DesktopSession _source(Project project) => _sources.firstWhere((source) => source.projects.contains(project));
  late String _page = widget.initialProject == null ? widget.initialPage : 'projects';
  late Project? _project = widget.initialProject;
  String _projectQuery = '';
  final _projectSearch = TextEditingController();
  final _scroll = ScrollController();

  void _select(String page) {
    if (_page == page && _project == null) return;
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() { _page = page; _project = null; });
  }

  void _editProject(Project project) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() { _page = 'projects'; _project = project; });
  }

  @override
  void dispose() {
    _projectSearch.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _back(BuildContext context) => TextButton.icon(
    onPressed: () => Navigator.pop(context),
    style: _navStyle(),
    icon: const Icon(Icons.arrow_back, size: 16),
    label: const Text('Back to app'));

  @override
  Widget build(BuildContext context) {
    final page = _pages.firstWhere((page) => page.id == _page);
    final project = _sources.any((source) => source.projects.contains(_project)) && _project?.removing != true ? _project : null;
    return Focus(autofocus: true, onKeyEvent: (_, event) {
      if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
      unawaited(Navigator.maybePop(context));
      return KeyEventResult.handled;
    }, child: Scaffold(backgroundColor: desktopSidebar, body: Column(children: [
      DesktopWindowDragRegion(child: SizedBox(height: widget.windowControls ? 40 : 8, width: double.infinity)),
      Expanded(child: Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x0d000000), width: .5),
          boxShadow: const [BoxShadow(color: Color(0x08000000), blurRadius: 3, offset: Offset(0, 1))]),
        child: Material(color: Colors.white, child: LayoutBuilder(builder: (context, bounds) {
          final wide = bounds.maxWidth >= 768;
          final gutter = ((bounds.maxWidth - 1048) / 2).clamp(0.0, double.infinity);
          final content = _page == 'archived'
            ? Padding(
                padding: EdgeInsets.fromLTRB(wide ? 4 : 24, wide ? 48 : 24, wide ? 4 : 24, 24),
                child: widget.archived)
            : SingleChildScrollView(controller: _scroll,
            padding: EdgeInsets.fromLTRB(wide ? 4 : 24, wide ? 48 : 24, wide ? 4 : 24, 80),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_page == 'projects' && project != null) ...[
                Align(alignment: Alignment.centerLeft, child: TextButton.icon(
                  onPressed: () => _select('projects'), style: _navStyle(),
                  icon: const Icon(Icons.arrow_back, size: 14), label: const Text('All projects'))),
                const SizedBox(height: 16),
                Row(children: [
                  ProjectAvatar(project: project, size: 32, generated: widget.session.projectAvatarStyle == 'generated'),
                  const SizedBox(width: 12),
                  Expanded(child: Text(project.name, style: const TextStyle(fontSize: 15,
                    fontWeight: FontWeight.w600, color: desktopForeground))),
                  _projectMenu(project),
                ]),
                const SizedBox(height: 6),
                const Text('Project settings', style: TextStyle(fontSize: 11, color: desktopSecondary)),
              ] else
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(page.label, style: const TextStyle(fontSize: 15, height: 20 / 15,
                      fontWeight: FontWeight.w600, color: desktopForeground)),
                    const SizedBox(height: 4),
                    Text(page.description, style: const TextStyle(fontSize: 11, height: 16 / 11, color: desktopSecondary)),
                  ])),
                  if (_page == 'projects' && _sources.any((source) => source.projects.isNotEmpty) && widget.addProject != null)
                    TextButton.icon(onPressed: widget.addProject, style: _navStyle(),
                      icon: const Icon(Icons.add, size: 16), label: const Text('Add project')),
                ]),
              const SizedBox(height: 24),
              if (widget.session.loginSucceeded) ...[
                Container(padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: const Color(0xffe3f1e8), borderRadius: BorderRadius.circular(8)),
                  child: Text('Signed in to ${widget.session.loginProvider == 'openai' ? 'ChatGPT' : 'OpenCode'}. Your account is connected.',
                    style: const TextStyle(fontSize: 13, color: Color(0xff296748)))),
                const SizedBox(height: 24),
              ],
              switch (_page) {
                'servers' => widget.machines == null ? const Text('Environments are unavailable')
                  : RemoteSettings(machines: widget.machines!),
                'providers' => widget.accounts,
                'appearance' => _appearance(),
                'shortcuts' => _settingsList([_PromptHistoryShortcutSettings(
                  controller: widget.session.promptHistoryShortcut, run: widget.run, shortcutError: widget.shortcutError)]),
                'projects' => project == null ? _projects() : _ProjectSettings(
                  key: ValueKey(projectIdentity(_source(project), project)), project: project, session: _source(project), run: widget.run,
                  removeProject: widget.removeProject),
                _ => _preferences(),
              },
            ]));
          if (!wide) {
            return Column(children: [
            Padding(padding: const EdgeInsets.fromLTRB(18, 12, 18, 0), child: Row(children: [
              Tooltip(message: 'Back', child: _back(context)),
              const Spacer(),
              PopupMenuButton<String>(tooltip: 'Settings pages', initialValue: _page, onSelected: _select,
                itemBuilder: (_) => [for (final item in _pages)
                  PopupMenuItem(value: item.id, child: Text(item.label))],
                child: MouseRegion(cursor: SystemMouseCursors.click,
                  child: Padding(padding: const EdgeInsets.all(6), child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(page.label, style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 6), const Icon(Icons.keyboard_arrow_down, size: 16),
                ])))),
            ])),
            Expanded(child: content),
            ]);
          }
          return Padding(padding: EdgeInsets.symmetric(horizontal: gutter), child: Row(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 328, child: Padding(padding: const EdgeInsets.fromLTRB(24, 50, 64, 48),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Tooltip(message: 'Back', child: _back(context)),
                  const SizedBox(height: 44),
                  Expanded(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (final item in _pages) ...[
                      if (item.id == 'preferences' || item.id == 'archived') const SizedBox(height: 16),
                      Padding(padding: const EdgeInsets.only(bottom: 4), child: TextButton.icon(
                        onPressed: () => _select(item.id),
                        style: _navStyle(selected: _page == item.id),
                        icon: Icon(item.icon, size: 16), label: Text(item.label))),
                    ],
                  ]))),
                ]))),
              Expanded(child: content),
            ]));
        })),
      )),
    ])));
  }

  Widget _preferences() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _settingsList([
      _settingsRow('Messages sent while a task is working', widget.session.deliveryMode == 'steer'
          ? 'Guide the current turn at the next model step.'
          : 'Wait for the current turn to finish, then start the next one.',
        _choice('Follow-up behavior', widget.session.deliveryMode, const {'steer': 'Steer', 'queue': 'Queue'},
          (value) => widget.run(() => widget.session.chooseDeliveryMode(value)))),
      _settingsRow('Dictation', widget.session.dictationMode == 'live'
          ? 'Show text while you speak. If live dictation is unavailable, transcribe when you stop.'
          : 'Record first, then insert the transcription when you stop.',
        _choice('Dictation', widget.session.dictationMode, const {'live': 'Live', 'on_stop': 'On stop'},
          (value) => widget.run(() => widget.session.chooseDictationMode(value)))),
      _NotificationPreferences(session: widget.session, run: widget.run),
    ]),
  ]);

  Widget _appearance() => _settingsList([
    DesktopAccentSettings(controller: widget.session.appearance, run: widget.run),
    ListenableBuilder(listenable: widget.session.pinnedSidebar, builder: (context, _) {
      final preferences = widget.session.pinnedSidebar;
      return _settingsRow('Pinned threads', 'Group projects with multiple pinned threads into collapsible folders.',
        _choice<PinnedThreadLayout>('Pinned threads', preferences.value.layout,
          const {PinnedThreadLayout.byProject: 'By project', PinnedThreadLayout.flat: 'Flat'},
          preferences.enabled ? (value) => widget.run(() => preferences.chooseLayout(value)) : null));
    }),
    _settingsRow('Project icons', 'Choose the marks shown beside your projects.',
      Row(mainAxisSize: MainAxisSize.min, children: [
        if (widget.session.project case final project?) ...[
          ProjectAvatar(project: project, size: 24, generated: widget.session.projectAvatarStyle == 'generated'),
          const SizedBox(width: 12),
        ],
        _choice('Project icons', widget.session.projectAvatarStyle, const {'letters': 'Letters', 'generated': 'Generated'},
          (value) => widget.run(() => widget.session.chooseProjectAvatarStyle(value))),
      ])),
  ]);

  Widget _projectMenu(Project project) => PopupMenuButton<String>(
    tooltip: 'Options for ${project.name}', icon: const Icon(Icons.more_horiz, size: 18),
    onSelected: (action) {
      switch (action) {
        case 'edit': _editProject(project);
        case 'open': unawaited(widget.openProject?.call(project));
        case 'copy': unawaited(widget.run(() => Clipboard.setData(ClipboardData(text: project.path))));
        case 'remove': unawaited(widget.removeProject?.call(project));
      }
    },
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'edit', child: Text('Edit project')),
      if (widget.openProject != null) PopupMenuItem(value: 'open', enabled: project.available, child: const Text('Open project')),
      const PopupMenuItem(value: 'copy', child: Text('Copy folder path')),
      if (widget.removeProject != null) const PopupMenuItem(value: 'remove', child: Text('Remove project')),
    ]);

  Widget _projects() {
    final projects = desktopProjects(_sources, preferred: widget.session);
    final query = _projectQuery.trim().toLowerCase();
    final filtered = projects.where((project) => query.isEmpty ||
      desktopProjectSearchText(project).toLowerCase().contains(query)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (projects.length > 7 || query.isNotEmpty) ...[
        TextField(decoration: _settingsInput('Search projects').copyWith(
          prefixIcon: const Icon(Icons.search, size: 16),
          suffixIcon: query.isEmpty ? null : IconButton(tooltip: 'Clear search',
            onPressed: () { _projectSearch.clear(); setState(() => _projectQuery = ''); },
            icon: const Icon(Icons.close, size: 14))),
          controller: _projectSearch, onChanged: (value) => setState(() => _projectQuery = value)),
        const SizedBox(height: 16),
      ],
      if (projects.isEmpty)
        _settingsList([Padding(padding: const EdgeInsets.symmetric(vertical: 64), child: Column(children: [
          const Icon(Icons.folder_outlined, size: 28, color: desktopSecondary),
          const SizedBox(height: 16),
          const Text('No projects yet', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          const Text('Add a project folder to get started.', style: TextStyle(fontSize: 13, color: desktopSecondary)),
          if (widget.addProject != null) ...[
            const SizedBox(height: 24),
            OutlinedButton.icon(onPressed: widget.addProject,
              icon: const Icon(Icons.add, size: 16), label: const Text('Add project')),
          ],
        ]))])
      else if (filtered.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(vertical: 48), child: Text('No projects match “${_projectQuery.trim()}”.',
          textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: desktopSecondary)))
      else
        _settingsList([for (final group in filtered)
          for (final project in [group.preferred.project])
          Row(children: [
            Expanded(child: TextButton(
              onPressed: () => _editProject(project),
              style: _navStyle().copyWith(padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 14))),
              child: Row(children: [
                ProjectAvatar(project: project, size: 24, generated: widget.session.projectAvatarStyle == 'generated'),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: desktopForeground)),
                  const SizedBox(height: 2),
                  Text(desktopProjectDescription(group), maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: desktopSecondary)),
                ])),
                if (!project.available) const Tooltip(message: 'Project folder is unavailable',
                  child: Padding(padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.warning_amber_rounded, size: 16, color: desktopSecondary))),
              ]))),
            _projectMenu(project),
          ]),
        ]),
    ]);
  }
}

class _PromptHistoryShortcutSettings extends StatefulWidget {
  const _PromptHistoryShortcutSettings({required this.controller, required this.run, this.shortcutError});
  final PromptHistoryShortcutController controller;
  final Future<void> Function(Future<void> Function()) run;
  final String? Function(SingleActivator)? shortcutError;

  @override
  State<_PromptHistoryShortcutSettings> createState() => _PromptHistoryShortcutSettingsState();
}

class _PromptHistoryShortcutSettingsState extends State<_PromptHistoryShortcutSettings> {
  final _focus = FocusNode();
  bool _recording = false;
  String? _error;

  @override
  void dispose() { _focus.dispose(); super.dispose(); }

  void _save(SingleActivator? shortcut) {
    setState(() { _recording = false; _error = null; });
    unawaited(widget.run(() => widget.controller.choose(shortcut)));
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (!_recording) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() { _recording = false; _error = null; });
      return KeyEventResult.handled;
    }
    if (shortcutModifierKeys.contains(event.logicalKey)) return KeyEventResult.handled;
    final keyboard = HardwareKeyboard.instance;
    final shortcut = SingleActivator(event.logicalKey, meta: keyboard.isMetaPressed,
      control: keyboard.isControlPressed, alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed, includeRepeats: false);
    final error = shortcutInputError(shortcut) ?? widget.shortcutError?.call(shortcut);
    if (error != null) { setState(() => _error = error); }
    else { _save(shortcut); }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.controller, builder: (context, _) {
    final state = widget.controller.state;
    final enabled = state is PromptHistoryShortcutReady || state is PromptHistoryShortcutFailed;
    final shortcut = state is PromptHistoryShortcutSaving ? state.pending : state.value;
    final description = _error ?? switch (state) {
      PromptHistoryShortcutLoading() => 'Loading shortcut…',
      PromptHistoryShortcutSaving() => 'Saving shortcut…',
      PromptHistoryShortcutFailed() => 'Could not save the shortcut. Try again.',
      _ when _recording => 'Press a key combination. Escape cancels.',
      _ => 'Search previous prompts in the current session. Also available in the command menu.',
    };
    return _settingsRow('Prompt history', description,
      Row(mainAxisSize: MainAxisSize.min, children: [
        Focus(focusNode: _focus, onKeyEvent: _key,
          onFocusChange: (focused) {
            if (!focused && _recording) setState(() { _recording = false; _error = null; });
          },
          child: OutlinedButton(onPressed: enabled ? () {
            setState(() { _recording = !_recording; _error = null; });
            if (_recording) _focus.requestFocus();
          } : null, child: Text(_recording ? 'Press shortcut…' : shortcut == null ? 'Record shortcut' : shortcutLabel(shortcut)))),
        if (shortcut != null) ...[
          const SizedBox(width: 8),
          TextButton(onPressed: enabled ? () => _save(null) : null, child: const Text('Clear')),
        ],
      ]));
  });
}

class _NotificationPreferences extends StatefulWidget {
  const _NotificationPreferences({required this.session, required this.run});
  final DesktopSession session;
  final Future<void> Function(Future<void> Function()) run;

  @override
  State<_NotificationPreferences> createState() => _NotificationPreferencesState();
}

class _NotificationPreferencesState extends State<_NotificationPreferences> {
  final _lifetime = CancellationToken();
  bool _requesting = false;
  String? _message;

  Future<void> _choose(String mode) async {
    if (_requesting) return;
    setState(() { _requesting = true; _message = null; });
    try {
      if (hasSystemNotifications(mode) &&
          !await requestDesktopNotificationPermission(cancellation: _lifetime)) {
        if (mounted) setState(() => _message = 'Allow Happen notifications in system settings, then choose this option again.');
        return;
      }
      await widget.session.chooseNotificationMode(mode).asCancellable(_lifetime);
    } on MissingPluginException {
      if (mounted) setState(() => _message = 'Relaunch Happen to enable system notifications.');
    } finally {
      if (mounted) setState(() => _requesting = false);
    }
  }

  @override
  void dispose() { _lifetime.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Column(children: [
    _settingsRow('Chat notifications', _message ?? (_requesting ? 'Waiting for notification permission…'
        : 'Sound and system alerts when a chat finishes, fails, or needs input. Applies to this device while Happen is open.'),
      AbsorbPointer(absorbing: _requesting, child: _choice('Chat notifications',
        widget.session.notificationMode, notificationModes, (mode) => unawaited(widget.run(() => _choose(mode)))))),
    _settingsRow('In-app notifications', 'Show an alert for other chats while Happen is in the foreground.',
      Switch.adaptive(value: widget.session.inAppNotificationsEnabled,
        onChanged: (enabled) => unawaited(widget.run(() => widget.session.chooseInAppNotifications(enabled))))),
  ]);
}

class _ProjectSettings extends StatefulWidget {
  const _ProjectSettings({super.key, required this.project, required this.session, required this.run, this.removeProject});
  final Project project;
  final DesktopSession session;
  final Future<void> Function(Future<void> Function()) run;
  final Future<void> Function(Project)? removeProject;

  @override
  State<_ProjectSettings> createState() => _ProjectSettingsState();
}

class _ProjectSettingsState extends State<_ProjectSettings> {
  late final _name = TextEditingController(text: widget.project.name);
  final _nameFocus = FocusNode();
  final _lifetime = CancellationToken();
  int _pendingNameSaves = 0;

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(_nameFocusChanged);
  }

  void _nameFocusChanged() {
    if (!_nameFocus.hasFocus) _saveName();
  }

  void _saveName() {
    final value = _name.text.trim();
    if (value == widget.project.name && _pendingNameSaves == 0) return;
    _pendingNameSaves++;
    unawaited(widget.run(() async {
      try {
        await widget.session.renameProject(widget.project, value);
      } finally {
        _pendingNameSaves--;
      }
    }));
  }

  @override
  void dispose() {
    _saveName();
    _lifetime.cancel();
    _nameFocus.removeListener(_nameFocusChanged);
    _nameFocus.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _chooseIcon() async {
    await showDialog<void>(context: context,
      builder: (_) => ProjectIconPicker(session: widget.session, project: widget.project));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.project.iconChanges,
    builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (!widget.project.available) ...[
      Container(padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: const Color(0xfffff6e5), borderRadius: BorderRadius.circular(8)),
        child: const Row(children: [
          Icon(Icons.folder_off_outlined, size: 20, color: desktopSecondary), SizedBox(width: 12),
          Expanded(child: Text('This project folder is unavailable. Check that it exists and any external drive is connected.',
            style: TextStyle(fontSize: 13, color: desktopSecondary))),
        ])),
      const SizedBox(height: 16),
    ],
    _projectSettingsSection('Project', [
      _settingsRow('Name', 'The name shown for this project in Happen.',
        SizedBox(width: 244, child: TextField(controller: _name, focusNode: _nameFocus,
          style: const TextStyle(fontSize: 13, color: desktopForeground),
          decoration: _settingsInput(widget.project.folderName).copyWith(labelText: 'Project name', floatingLabelBehavior: FloatingLabelBehavior.never),
          onSubmitted: (_) => _saveName(), onTapOutside: (_) => _nameFocus.unfocus()))),
      if (widget.session.projectIconSource(widget.project) != null) _settingsRow('Project icon', switch (widget.project.iconState) {
        ProjectIconSaving() => 'Saving project icon…',
        ProjectIconFailed(:final message) => message,
        final state => state.value.error ?? 'Choose an icon, emoji, monogram, or local image file.',
      },
        Row(mainAxisSize: MainAxisSize.min, children: [
          Tooltip(message: 'Choose project icon', child: InkWell(
            onTap: _canChooseIcon ? () => unawaited(_chooseIcon()) : null,
            borderRadius: BorderRadius.circular(6), child: Padding(padding: const EdgeInsets.all(4),
              child: ProjectAvatar(project: widget.project, size: 32, generated: widget.session.projectAvatarStyle == 'generated')))),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: _canChooseIcon ? () => unawaited(_chooseIcon()) : null,
            child: const Text('Choose icon')),
          if (widget.project.icon != null) ...[
            const SizedBox(width: 8),
            TextButton(onPressed: _canChooseIcon ? () => unawaited(widget.run(() =>
              widget.session.chooseProjectIcon(widget.project, null, cancellation: _lifetime))) : null,
              child: const Text('Reset')),
          ],
        ])),
    ]),
    const SizedBox(height: 24),
    _ProjectActionsSettings(project: widget.project, session: widget.session, run: widget.run),
    const SizedBox(height: 24),
    _projectSettingsSection('Checkouts', [
      Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.folder_outlined, size: 18, color: desktopSecondary)),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(machineLabel(widget.session),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: desktopForeground)),
          const SizedBox(height: 6),
          SelectableText(widget.project.path, style: const TextStyle(fontSize: 12, color: desktopSecondary)),
          if (widget.project.branch case final branch?) ...[
            const SizedBox(height: 6),
            Row(children: [const Icon(Icons.call_split_rounded, size: 14, color: desktopSecondary), const SizedBox(width: 4),
              Expanded(child: Text(branch, style: const TextStyle(fontSize: 12, color: desktopSecondary)))]),
          ],
        ])),
        const SizedBox(width: 8),
        IconButton(tooltip: 'Copy project path', icon: const Icon(Icons.copy_outlined, size: 16),
          onPressed: () => unawaited(widget.run(() => Clipboard.setData(ClipboardData(text: widget.project.path))))),
        if (widget.session.client.sharedFilesystem)
          IconButton(tooltip: 'Open project folder', icon: const Icon(Icons.open_in_new_rounded, size: 16),
            onPressed: widget.project.available ? () => unawaited(widget.run(() => widget.session.openProjectFolder(widget.project))) : null),
      ])),
    ]),
    if (widget.removeProject != null) ...[
      const SizedBox(height: 24),
      _projectSettingsSection('Danger', [
        _settingsRow('Remove project', 'Remove this project and its threads from Happen. The folder and saved thread history are kept.',
          OutlinedButton.icon(onPressed: () => unawaited(widget.removeProject!(widget.project)),
            style: OutlinedButton.styleFrom(foregroundColor: desktopError,
              side: const BorderSide(color: Color(0x40c23838))),
            icon: const Icon(Icons.delete_outline_rounded, size: 16), label: const Text('Remove project'))),
      ]),
    ],
  ]));

  bool get _canChooseIcon => widget.session.projectIconSource(widget.project)?.available == true &&
    !widget.project.removing && widget.project.iconState is! ProjectIconSaving;
}

Widget _projectSettingsSection(String title, List<Widget> rows) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Padding(padding: const EdgeInsets.only(left: 4, bottom: 10), child: Text(title,
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: desktopSecondary))),
    _settingsList(rows),
  ]);

class _ProjectActionsSettings extends StatefulWidget {
  const _ProjectActionsSettings({required this.project, required this.session, required this.run});
  final Project project;
  final DesktopSession session;
  final Future<void> Function(Future<void> Function()) run;
  @override
  State<_ProjectActionsSettings> createState() => _ProjectActionsSettingsState();
}

class _ProjectActionsSettingsState extends State<_ProjectActionsSettings> {
  final _lifetime = CancellationToken();
  ProjectActionsController get actions => widget.session.actionsForProject(widget.project);
  @override
  void initState() { super.initState(); unawaited(actions.load()); }
  @override
  void dispose() { _lifetime.cancel(); super.dispose(); }

  void _edit([ProjectScript? script]) => unawaited(showDialog<void>(context: context,
    builder: (context) => ProjectScriptDialog(controller: actions, script: script)));

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: actions, builder: (context, _) {
    final state = actions.state;
    final ready = state is ProjectActionsReady || state is ProjectActionsFailed;
    final scripts = state.value.scripts;
    return _projectSettingsSection('Actions', [
      _settingsRow('Open project in', 'The application used to open this checkout.',
        PopupMenuButton<String>(tooltip: 'Choose application', enabled: ready && actions.local,
          onSelected: (id) => unawaited(widget.run(() => actions.save((opener: id, scripts: scripts), _lifetime))),
          itemBuilder: (_) => [for (final target in actions.openers)
            CheckedPopupMenuItem(value: target.id, checked: target.id == actions.opener.id, child: Text(target.label))],
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(state is ProjectActionsLoading ? 'Loading…' : state is ProjectActionsSaving ? 'Saving…' : actions.opener.label,
              style: TextStyle(fontSize: 13, color: ready && actions.local ? desktopForeground : desktopSecondary)),
            const SizedBox(width: 8), const Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: desktopSecondary),
          ])))),
      _settingsRow('Project scripts', 'Saved commands available in this project’s terminal.',
        OutlinedButton.icon(onPressed: ready ? _edit : null,
          icon: const Icon(Icons.add_rounded, size: 16), label: const Text('Add script'))),
      for (final script in scripts)
        Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Row(children: [
          const Icon(Icons.terminal_rounded, size: 18, color: desktopSecondary), const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(script.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: desktopForeground)),
            const SizedBox(height: 4),
            Text(script.command, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontFamily: desktopMonoFamily, color: desktopSecondary)),
          ])),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: ready ? () => _edit(script) : null, child: const Text('Edit')),
        ])),
      if (state case ProjectActionsFailed(:final message))
        Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Align(alignment: Alignment.centerLeft,
          child: Text(message, style: const TextStyle(fontSize: 12, color: desktopError)))),
    ]);
  });
}

InputDecoration _settingsInput(String hint) => InputDecoration(
  hintText: hint, filled: true, fillColor: Colors.white,
  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
    borderSide: const BorderSide(color: Color(0x1f000000), width: .5)),
  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
    borderSide: const BorderSide(color: desktopForeground, width: 1)));

ButtonStyle _navStyle({bool selected = false}) => TextButton.styleFrom(
  visualDensity: VisualDensity.standard,
  alignment: Alignment.centerLeft,
  foregroundColor: selected ? desktopForeground : desktopSecondary,
  backgroundColor: selected ? const Color(0xffeeeeee) : Colors.transparent,
  textStyle: const TextStyle(fontFamily: desktopFontFamily, fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w400),
  minimumSize: const Size(0, 28), padding: const EdgeInsets.symmetric(horizontal: 6),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)));

Widget _settingsList(List<Widget> rows) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 20),
  decoration: BoxDecoration(color: desktopSidebar, borderRadius: BorderRadius.circular(8),
    border: Border.all(color: const Color(0x14000000), width: .5)),
  child: Column(children: [for (var index = 0; index < rows.length; index++) ...[
    if (index > 0) const Divider(height: .5, thickness: .5, color: desktopBorder),
    rows[index],
  ]]));

Widget _settingsRow(String title, String description, Widget control) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 20),
  child: LayoutBuilder(builder: (context, bounds) {
    final copy = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w500, color: desktopForeground)),
      const SizedBox(height: 4),
      Text(description, style: const TextStyle(fontSize: 13, height: 20 / 13, color: desktopSecondary)),
    ]);
    if (bounds.maxWidth < 420) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        copy, const SizedBox(height: 16), Align(alignment: Alignment.centerRight,
          child: ConstrainedBox(constraints: BoxConstraints(maxWidth: bounds.maxWidth), child: control)),
      ]);
    }
    return Row(children: [Expanded(child: copy), const SizedBox(width: 16), control]);
  }));

Widget _choice<T>(String label, T value, Map<T, String> options, ValueChanged<T>? onChanged) =>
  Semantics(label: label, child: Container(
    height: 28,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6),
      border: Border.all(color: const Color(0x1f000000), width: .5)),
    child: DropdownButtonHideUnderline(child: DropdownButton<T>(
      value: value, isDense: true, borderRadius: BorderRadius.circular(6),
      padding: EdgeInsets.zero,
      dropdownColor: Colors.white,
      style: const TextStyle(fontFamily: desktopFontFamily, fontSize: 13, height: 16 / 13, color: desktopForeground),
      icon: const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.keyboard_arrow_down, size: 14, color: desktopSecondary)),
      items: [for (final entry in options.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value))],
      onChanged: onChanged == null ? null : (value) { if (value != null) onChanged(value); },
    ))));
