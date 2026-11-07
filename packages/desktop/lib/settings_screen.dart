import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:macos_file_picker/macos_file_picker.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'app_icon.dart';
import 'native_app_icon.dart';
import 'composer_attachments.dart';
import 'project_avatar.dart';
import 'session.dart';
import 'desktop_notifications.dart';
import 'notification_preferences.dart';
import 'window_chrome.dart';

const _pages = [
  (id: 'providers', label: 'Providers', icon: Icons.key_outlined,
    description: 'Manage the accounts you use for AI models'),
  (id: 'preferences', label: 'Preferences', icon: Icons.tune,
    description: 'Customize preferences and default behavior'),
  (id: 'appearance', label: 'Appearance', icon: Icons.palette_outlined,
    description: 'Customize how Happen looks'),
  (id: 'projects', label: 'Projects', icon: Icons.folder_outlined,
    description: 'Manage your projects and customize their appearance'),
  (id: 'archived', label: 'Archived tasks', icon: Icons.archive_outlined,
    description: 'View past conversations or restore them to continue'),
];

// OpenCode: app/src/settings/{navigation.tsx,settings.css}; only supported pages are listed.
class DesktopSettingsScreen extends StatefulWidget {
  const DesktopSettingsScreen({super.key, required this.session, required this.accounts,
    required this.archived, required this.run, this.addProject, this.openProject,
    this.removeProject, this.windowControls = true, this.initialPage = 'preferences'});
  final DesktopSession session;
  final Widget accounts, archived;
  final Future<void> Function(Future<void> Function()) run;
  final Future<void> Function()? addProject;
  final Future<void> Function(Project)? openProject, removeProject;
  final bool windowControls;
  final String initialPage;

  @override
  State<DesktopSettingsScreen> createState() => _DesktopSettingsScreenState();
}

class _DesktopSettingsScreenState extends State<DesktopSettingsScreen> {
  late String _page = widget.initialPage;
  Project? _project;
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
    final project = widget.session.projects.contains(_project) && _project?.removing != true ? _project : null;
    return Focus(autofocus: true, onKeyEvent: (_, event) {
      if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
      unawaited(Navigator.maybePop(context));
      return KeyEventResult.handled;
    }, child: Scaffold(backgroundColor: const Color(0xfffafafa), body: Column(children: [
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
                    fontWeight: FontWeight.w600, color: opencodeInk))),
                  _projectMenu(project),
                ]),
              ] else
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(page.label, style: const TextStyle(fontSize: 15, height: 20 / 15,
                      fontWeight: FontWeight.w600, color: opencodeInk)),
                    const SizedBox(height: 4),
                    Text(page.description, style: const TextStyle(fontSize: 11, height: 16 / 11, color: opencodeMuted)),
                  ])),
                  if (_page == 'projects' && widget.session.projects.isNotEmpty && widget.addProject != null)
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
                'providers' => widget.accounts,
                'appearance' => _appearance(),
                'projects' => project == null ? _projects() : _ProjectSettings(
                  key: ValueKey(project.checkoutKey), project: project, session: widget.session, run: widget.run),
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
                child: Padding(padding: const EdgeInsets.all(6), child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(page.label, style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 6), const Icon(Icons.keyboard_arrow_down, size: 16),
                ]))),
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
    if (supportsAppIconSwitching)
      ListenableBuilder(listenable: widget.session.appIcon, builder: (context, _) {
        final state = widget.session.appIcon.state;
        final enabled = state is AppIconReady || state is AppIconFailed;
        final description = switch (state) {
          AppIconFailed() => 'Could not update the app icon. Try choosing it again.',
          AppIconLoading() || AppIconSaving() => 'Updating app icon…',
          _ => Platform.isMacOS ? 'Choose the icon shown in the Dock.' : 'Choose the icon shown for Happen windows.',
        };
        void choose(AppIconChoice? choice) {
          final current = widget.session.appIcon.state;
          if ((current is AppIconReady || current is AppIconFailed) && choice != null) {
            unawaited(widget.run(() => widget.session.appIcon.choose(choice)));
          }
        }
        return Padding(padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('App icon', style: TextStyle(fontSize: 13, height: 16 / 13,
              fontWeight: FontWeight.w500, color: opencodeInk)),
            const SizedBox(height: 4),
            Text(description, style: const TextStyle(fontSize: 13, height: 20 / 13, color: opencodeMuted)),
            const SizedBox(height: 16),
            RadioGroup<AppIconChoice>(groupValue: state.value, onChanged: choose,
              child: Wrap(spacing: 12, runSpacing: 12, children: [
                for (final choice in AppIconChoice.values)
                  _appIconChoice(choice, selected: state.value == choice, enabled: enabled,
                    onSelected: () => choose(choice)),
              ])),
          ]));
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
    final projects = widget.session.projects.where((project) => !project.removing).toList();
    final query = _projectQuery.trim().toLowerCase();
    final filtered = projects.where((project) => query.isEmpty ||
      project.name.toLowerCase().contains(query) || project.path.toLowerCase().contains(query)).toList();
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
          const Icon(Icons.folder_outlined, size: 28, color: opencodeMuted),
          const SizedBox(height: 16),
          const Text('No projects yet', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
          const Text('Add a project folder to get started.', style: TextStyle(fontSize: 13, color: opencodeMuted)),
          if (widget.addProject != null) ...[
            const SizedBox(height: 24),
            OutlinedButton.icon(onPressed: widget.addProject,
              icon: const Icon(Icons.add, size: 16), label: const Text('Add project')),
          ],
        ]))])
      else if (filtered.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(vertical: 48), child: Text('No projects match “${_projectQuery.trim()}”.',
          textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, color: opencodeMuted)))
      else
        _settingsList([for (final project in filtered)
          Row(children: [
            Expanded(child: TextButton(
              onPressed: () => _editProject(project),
              style: _navStyle().copyWith(padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 14))),
              child: Row(children: [
                ProjectAvatar(project: project, size: 24, generated: widget.session.projectAvatarStyle == 'generated'),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: opencodeInk)),
                  const SizedBox(height: 2),
                  Text(project.path, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: opencodeMuted)),
                ])),
                if (!project.available) const Tooltip(message: 'Project folder is unavailable',
                  child: Padding(padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.warning_amber_rounded, size: 16, color: opencodeMuted))),
              ]))),
            _projectMenu(project),
          ]),
        ]),
    ]);
  }
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
  const _ProjectSettings({super.key, required this.project, required this.session, required this.run});
  final Project project;
  final DesktopSession session;
  final Future<void> Function(Future<void> Function()) run;

  @override
  State<_ProjectSettings> createState() => _ProjectSettingsState();
}

class _ProjectSettingsState extends State<_ProjectSettings> {
  late final _name = TextEditingController(text: widget.project.name);
  final _nameFocus = FocusNode();
  final _lifetime = CancellationToken();
  int _pendingNameSaves = 0;
  bool _loadingIcon = false, _receivingIcon = false, _dragOver = false;

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
    if (_loadingIcon || _receivingIcon) return;
    final paths = await MacosFilePicker().pick(MacosFilePickerMode.file,
      allowsMultiple: false, allowedUtiTypes: ['public.image'], dialogTitle: 'Choose project icon');
    try {
      if (mounted && paths != null && paths.isNotEmpty) await _loadIcon(paths.first.path);
    } finally {
      for (final path in paths ?? <MacosFilePickerPath>[]) { await path.release(); }
    }
  }

  Future<void> _loadIcon(String path) async {
    if (_loadingIcon || !mounted) return;
    setState(() => _loadingIcon = true);
    try {
      final file = File(path);
      if (await file.length() > 8 * 1024 * 1024) throw ArgumentError('Choose an image smaller than 8 MB');
      _lifetime.throwIfCancelled();
      final bytes = await file.readAsBytes();
      _lifetime.throwIfCancelled();
      final codec = await ui.instantiateImageCodecWithSize(await ui.ImmutableBuffer.fromUint8List(bytes),
        getTargetSize: (width, height) => width <= 128 && height <= 128 ? const ui.TargetImageSize()
          : width >= height ? const ui.TargetImageSize(width: 128) : const ui.TargetImageSize(height: 128));
      try {
        _lifetime.throwIfCancelled();
        final frame = await codec.getNextFrame();
        try {
          _lifetime.throwIfCancelled();
          final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
          _lifetime.throwIfCancelled();
          if (png == null) throw StateError('Could not read this image');
          await widget.session.chooseProjectAvatarImage(widget.project, png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes));
        } finally { frame.image.dispose(); }
      } finally { codec.dispose(); }
    } finally {
      if (mounted) setState(() => _loadingIcon = false);
    }
  }

  Future<void> _dropIcon(DropDetails details) => widget.run(() async {
    if (_loadingIcon || _receivingIcon) return;
    setState(() { _dragOver = false; _receivingIcon = true; });
    try {
      final attachments = await receiveComposerDrop(details, widget.session.attachmentDirectory, _lifetime);
      try {
        if (attachments.isNotEmpty) await _loadIcon(attachments.first.path);
      } finally {
        for (final attachment in attachments) { await attachment.discard(); }
      }
    } finally {
      if (mounted) setState(() => _receivingIcon = false);
    }
  });

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    if (!widget.project.available) ...[
      Container(padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: const Color(0xfffff6e5), borderRadius: BorderRadius.circular(8)),
        child: const Row(children: [
          Icon(Icons.folder_off_outlined, size: 20, color: opencodeMuted), SizedBox(width: 12),
          Expanded(child: Text('This project folder is unavailable. Check that it exists and any external drive is connected.',
            style: TextStyle(fontSize: 13, color: opencodeMuted))),
        ])),
      const SizedBox(height: 16),
    ],
    _settingsList([
      _settingsRow('Name', 'The name shown for this project in Happen.',
        SizedBox(width: 244, child: TextField(controller: _name, focusNode: _nameFocus,
          style: const TextStyle(fontSize: 13, color: opencodeInk),
          decoration: _settingsInput(widget.project.folderName).copyWith(labelText: 'Project name', floatingLabelBehavior: FloatingLabelBehavior.never),
          onSubmitted: (_) => _saveName(), onTapOutside: (_) => _nameFocus.unfocus()))),
      _settingsRow('Icon', 'Upload an image or drop one onto the icon.',
        Row(mainAxisSize: MainAxisSize.min, children: [
          DropTarget(enabled: !_loadingIcon && !_receivingIcon, acceptedKinds: const {DropItemKind.file},
            onEnter: (_) => setState(() => _dragOver = true),
            onLeave: () { if (mounted) setState(() => _dragOver = false); },
            onDrop: _dropIcon,
            child: Tooltip(message: 'Choose project icon', child: InkWell(
              onTap: _loadingIcon || _receivingIcon ? null : () => unawaited(widget.run(_chooseIcon)),
              borderRadius: BorderRadius.circular(6),
              child: Container(padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _dragOver ? opencodeInk : Colors.transparent)),
                child: _loadingIcon || _receivingIcon ? const SizedBox.square(dimension: 32, child: CircularProgressIndicator(strokeWidth: 2))
                  : ProjectAvatar(project: widget.project, size: 32, generated: widget.session.projectAvatarStyle == 'generated'))))),
          if (widget.project.avatarImage != null) ...[
            const SizedBox(width: 8),
            IconButton(tooltip: 'Remove custom icon', icon: const Icon(Icons.close, size: 16),
              onPressed: _loadingIcon || _receivingIcon ? null : () => unawaited(widget.run(() => widget.session.chooseProjectAvatarImage(widget.project, null)))),
          ],
        ])),
      if (widget.project.avatarImage == null)
        _settingsRow('Color', 'Choose a color for the project icon.',
          SizedBox(width: 244, child: Wrap(spacing: 8, runSpacing: 12, alignment: WrapAlignment.end, children: [
            for (final color in opencodeProjectColors.keys) _projectColor(widget.project, color),
          ]))),
      _settingsRow('Folder', 'The local folder used for this project.',
        SizedBox(width: 244, child: SelectableText(widget.project.path,
          style: const TextStyle(fontSize: 12, color: opencodeMuted)))),
    ]),
  ]);

  Widget _projectColor(Project project, String color) {
    final selected = (project.avatarColor ?? 'gray') == color;
    return Tooltip(message: 'Use $color for ${project.name}', child: Semantics(selected: selected,
      child: DecoratedBox(
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), boxShadow: selected ? const [
          BoxShadow(color: opencodeInk, spreadRadius: 4),
          BoxShadow(color: Color(0xfffafafa), spreadRadius: 2),
        ] : null),
        child: InkWell(borderRadius: BorderRadius.circular(6),
          onTap: () => unawaited(widget.run(() => widget.session.chooseProjectAvatarColor(project, selected ? null : color))),
          child: SizedBox.square(dimension: 20, child: Stack(alignment: Alignment.center, children: [
            ProjectAvatar(project: project, color: color, label: '', size: 20),
            if (selected) const Icon(Icons.check, size: 14, color: Colors.white),
          ]))),
      )));
  }
}

InputDecoration _settingsInput(String hint) => InputDecoration(
  hintText: hint, filled: true, fillColor: Colors.white,
  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
    borderSide: const BorderSide(color: Color(0x1f000000), width: .5)),
  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6),
    borderSide: const BorderSide(color: opencodeInk, width: 1)));

ButtonStyle _navStyle({bool selected = false}) => TextButton.styleFrom(
  visualDensity: VisualDensity.standard,
  alignment: Alignment.centerLeft,
  foregroundColor: selected ? opencodeInk : opencodeMuted,
  backgroundColor: selected ? const Color(0xffeeeeee) : Colors.transparent,
  textStyle: const TextStyle(fontFamily: 'Inter', fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w400),
  minimumSize: const Size(0, 28), padding: const EdgeInsets.symmetric(horizontal: 6),
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)));

Widget _settingsList(List<Widget> rows) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 20),
  decoration: BoxDecoration(color: const Color(0xfffafafa), borderRadius: BorderRadius.circular(8),
    border: Border.all(color: const Color(0x14000000), width: .5)),
  child: Column(children: [for (var index = 0; index < rows.length; index++) ...[
    if (index > 0) const Divider(height: .5, thickness: .5, color: opencodeBorder),
    rows[index],
  ]]));

Widget _settingsRow(String title, String description, Widget control) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 20),
  child: LayoutBuilder(builder: (context, bounds) {
    final copy = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w500, color: opencodeInk)),
      const SizedBox(height: 4),
      Text(description, style: const TextStyle(fontSize: 13, height: 20 / 13, color: opencodeMuted)),
    ]);
    if (bounds.maxWidth < 420) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        copy, const SizedBox(height: 16), Align(alignment: Alignment.centerRight,
          child: ConstrainedBox(constraints: BoxConstraints(maxWidth: bounds.maxWidth), child: control)),
      ]);
    }
    return Row(children: [Expanded(child: copy), const SizedBox(width: 16), control]);
  }));

Widget _choice(String label, String value, Map<String, String> options, ValueChanged<String> onChanged) =>
  Semantics(label: label, child: Container(
    height: 28,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6),
      border: Border.all(color: const Color(0x1f000000), width: .5)),
    child: DropdownButtonHideUnderline(child: DropdownButton<String>(
      value: value, isDense: true, borderRadius: BorderRadius.circular(6),
      padding: EdgeInsets.zero,
      dropdownColor: Colors.white,
      style: const TextStyle(fontFamily: 'Inter', fontSize: 13, height: 16 / 13, color: opencodeInk),
      icon: const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.keyboard_arrow_down, size: 14, color: opencodeMuted)),
      items: [for (final entry in options.entries) DropdownMenuItem(value: entry.key, child: Text(entry.value))],
      onChanged: (value) { if (value != null) onChanged(value); },
    ))));

Widget _appIconChoice(AppIconChoice choice, {required bool selected, required bool enabled,
  required VoidCallback onSelected}) => MergeSemantics(child: Opacity(opacity: enabled ? 1 : .55,
  child: Material(color: selected ? const Color(0xfff0f0f0) : Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: selected ? opencodeInk : opencodeBorder, width: selected ? 1.5 : .5)),
    clipBehavior: Clip.antiAlias,
    child: InkWell(onTap: enabled ? onSelected : null, canRequestFocus: false, excludeFromSemantics: true,
      child: SizedBox(width: 144, child: Padding(padding: const EdgeInsets.all(12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ExcludeSemantics(child: Image.asset(appIconPreviewAsset(choice), width: 88, height: 88,
            filterQuality: FilterQuality.medium)),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Radio<AppIconChoice>(value: choice, enabled: enabled, activeColor: opencodeInk,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, visualDensity: VisualDensity.compact),
            const SizedBox(width: 4),
            Flexible(child: Text(choice.label,
              style: const TextStyle(fontSize: 13, height: 16 / 13, color: opencodeInk))),
          ]),
        ])))))));
