import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'conversation_indicator.dart';
import 'project_avatar.dart';
import 'provider_icon.dart';
import 'rename_state.dart';
import 'session.dart';
import 'sidebar_hover.dart';
import 'sidebar_icons.dart';
import 'window_chrome.dart';

List<(Project, DesktopTask)> _sidebarTasks(DesktopSession session, String? projectKey) {
  final pins = {for (final (index, id) in session.pinnedTaskIds.indexed) id: index};
  final tasks = [
    for (final project in session.projects)
      if (!project.removing && (projectKey == null || project.checkoutKey == projectKey))
        for (final task in project.tasks)
          if (!task.archived) (project, task),
  ];
  final sentAt = {for (final (_, task) in tasks) if (task.running) task.id: taskLastSentAt(task)};
  return tasks..sort((a, b) {
    final pin = (pins[a.$2.id] ?? double.infinity).compareTo(pins[b.$2.id] ?? double.infinity);
    if (pin != 0) return pin;
    if (a.$2.running != b.$2.running) return a.$2.running ? -1 : 1;
    if (a.$2.running) {
      final sent = sentAt[b.$2.id]!.compareTo(sentAt[a.$2.id]!);
      return sent != 0 ? sent : a.$2.id.compareTo(b.$2.id);
    }
    final activity = b.$2.lastActivity.compareTo(a.$2.lastActivity);
    return activity != 0 ? activity : a.$2.id.compareTo(b.$2.id);
  });
}

List<SessionDraft> _sidebarDrafts(DesktopSession session, String? projectKey) =>
  session.sessionDrafts.where((draft) => draft.submission == null &&
    (projectKey == null || draft.checkoutKey == projectKey) &&
    ((session.drafts[draft.id] ?? '').trim().isNotEmpty ||
      (session.fileDrafts[draft.id]?.isNotEmpty ?? false) ||
      (session.attachmentDrafts[draft.id]?.isNotEmpty ?? false))).toList().reversed.toList();

List<String> sidebarThreadIds(DesktopSession session, {String? projectKey}) {
  final tasks = _sidebarTasks(session, projectKey);
  final pins = session.pinnedTaskIds.toSet();
  return [
    for (final (_, task) in tasks.where((entry) => pins.contains(entry.$2.id)))
      task.id,
    for (final (_, task) in tasks.where((entry) => entry.$2.running && !pins.contains(entry.$2.id)))
      if (!session.collapsedSidebarSections.contains('working') || session.task == task) task.id,
    for (final draft in _sidebarDrafts(session, projectKey)) draft.id,
    for (final (_, task) in tasks.where((entry) => !entry.$2.running && !pins.contains(entry.$2.id))) task.id,
  ];
}

class ThreadSidebar extends StatefulWidget {
  const ThreadSidebar({super.key, required this.session, required this.home, required this.windowControls,
    required this.onHome, required this.onSearch, required this.onNew, required this.onSettings,
    required this.onSelect, required this.onArchive, required this.onDraft,
    required this.onAddProject, required this.onRefresh, required this.onProjectFilter,
    this.projectKey, this.titlebarInset = 0, this.onBack, this.onForward});
  final DesktopSession session;
  final bool home, windowControls;
  final double titlebarInset;
  final String? projectKey;
  final VoidCallback onHome, onSearch, onNew, onSettings, onAddProject, onRefresh;
  final VoidCallback? onBack, onForward;
  final ValueChanged<String?> onProjectFilter;
  final void Function(Project, DesktopTask) onSelect;
  final void Function(DesktopTask, bool) onArchive;
  final ValueChanged<SessionDraft> onDraft;

  @override
  State<ThreadSidebar> createState() => _ThreadSidebarState();
}

class _ThreadSidebarState extends State<ThreadSidebar> {
  DesktopSession get session => widget.session;
  Timer? _clock;
  bool _reordering = false;
  late final _pinnedList = GlobalKey<SliverReorderableListState>();

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() { _clock?.cancel(); super.dispose(); }

  Widget _button(String tooltip, Widget icon, VoidCallback? onPressed) => IconButton(
    tooltip: tooltip, onPressed: onPressed,
    style: IconButton.styleFrom(minimumSize: const Size.square(28), maximumSize: const Size.square(28),
      padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: onPressed == null ? const Color(0xffb5b5bd) : const Color(0xff7c7c89),
      iconSize: 16, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
    icon: icon);

  Widget _dragBoundary(String label) => AnimatedSize(alignment: Alignment.topCenter,
    duration: const Duration(milliseconds: 150), child: !_reordering ? const SizedBox.shrink()
      : SizedBox(height: 24, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Row(children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: conversationSecondary)),
      const SizedBox(width: 8),
      const Expanded(child: Divider(height: 1, color: Color(0xffd4d4d8))),
    ]))));

  Widget _dragProxy(Widget child, int index, Animation<double> animation) =>
    AnimatedBuilder(animation: animation, child: child, builder: (context, child) => MouseRegion(
      cursor: SystemMouseCursors.grabbing, child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(6),
          boxShadow: [BoxShadow(color: Color.fromRGBO(0, 0, 0, .12 * animation.value),
            blurRadius: 16 * animation.value, offset: Offset(0, 4 * animation.value))]),
        child: child)));

  Widget _sectionHeading(String section, String title, int count) {
    final expanded = !session.collapsedSidebarSections.contains(section);
    return InkWell(key: ValueKey('$section-section'),
      onTap: () => unawaited(_run(session, () => session.chooseSidebarSection(section, expanded))),
      borderRadius: BorderRadius.circular(6), child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: Row(children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 12, color: Color(0xff72727f)))),
          Text('$count', style: const TextStyle(fontSize: 12, color: Color(0xff9696a0))),
          const SizedBox(width: 8),
          Icon(expanded ? Icons.keyboard_arrow_down_rounded : Icons.chevron_right_rounded, size: 14, color: opencodeFaint),
        ])));
  }

  Widget _row(Project project, DesktopTask task, {int? reorderIndex}) => _ThreadRow(
    key: ValueKey('thread-row:${task.id}'), session: session, task: task, onArchive: widget.onArchive,
    builder: (renameInput) => SidebarHover(builder: (context, hovering) {
      final selected = !widget.home && session.task == task;
      final pinned = session.pinnedTaskIds.contains(task.id);
      final unread = task.lastActivity > (session.viewedTasks[task.id] ?? -1);
      final reorderable = reorderIndex != null && renameInput == null && !task.archiving && !session.savingTaskPins;
      final card = Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Material(
        color: selected ? Colors.white : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6),
          side: BorderSide(color: selected ? const Color(0xffe4e4e7) : Colors.transparent)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(key: ValueKey('thread:${task.id}'), borderRadius: BorderRadius.circular(6),
          mouseCursor: reorderable && renameInput == null ? SystemMouseCursors.grab : SystemMouseCursors.click,
          hoverColor: const Color(0xfff4f4f5),
          onTap: renameInput == null ? () => widget.onSelect(project, task) : null,
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(height: 20, child: Row(children: [
                ProjectAvatar(project: project, size: 16, generated: session.projectAvatarStyle == 'generated'),
                const SizedBox(width: 6),
                if (pinned) ...[
                  _pinButton(session, task, compact: true),
                  const SizedBox(width: 6),
                ],
                Expanded(child: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: conversationSecondary))),
                if (hovering) ...[
                  if (!pinned) _pinButton(session, task),
                  SizedBox.square(dimension: 22, child: IconButton(tooltip: 'Archive session',
                    padding: EdgeInsets.zero, onPressed: session.connected && !task.archiving
                      ? () => widget.onArchive(task, true) : null,
                    icon: const Icon(Icons.archive_outlined, size: 14, color: opencodeFaint))),
                ] else ...[
                  _ThreadStatus(session: session, task: task, showLabel: true),
                ],
              ])),
              const SizedBox(height: 4),
              renameInput ?? Tooltip(message: task.title, child: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, height: 20 / 14,
                  fontWeight: selected || unread ? FontWeight.w500 : FontWeight.w400,
                  color: selected || unread ? const Color(0xff18181b) : const Color(0xff52525b)))),
              const SizedBox(height: 2),
              SizedBox(height: 16, child: Row(children: [
                if (project.branch case final branch?) Expanded(child: Text(branch, maxLines: 1,
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: conversationSecondary))))
                else const Spacer(),
                if (task.provider != null) Tooltip(message: '${task.provider}${task.model == null ? '' : ' · ${task.model}'}',
                  child: providerIcon(task.provider, size: 14, color: const Color(0xffa1a1aa))),
              ])),
            ])))));
      return reorderIndex == null ? card : ReorderableDragStartListener(
        index: reorderIndex, enabled: reorderable, child: card);
    }));

  Widget _draft(SessionDraft draft) {
    final project = session.projects.where((project) => project.checkoutKey == draft.checkoutKey).firstOrNull;
    var text = session.drafts[draft.id] ?? '';
    for (final file in (session.fileDrafts[draft.id] ?? []).reversed) {
      if (file.offset < 0 || file.offset >= text.length || text[file.offset] != '\uFFFC') continue;
      text = text.replaceRange(file.offset, file.offset + 1, '${file.skillName == null ? '@' : r'$'}${file.label}');
    }
    text = text.trim().split('\n').first;
    final count = (session.fileDrafts[draft.id]?.length ?? 0) + (session.attachmentDrafts[draft.id]?.length ?? 0);
    final selected = !widget.home && session.task == null && session.currentDraft == draft;
    return Material(key: ValueKey('draft:${draft.id}'), color: selected ? const Color(0xffeeeef0) : Colors.transparent,
      borderRadius: BorderRadius.circular(8), child: InkWell(
        borderRadius: BorderRadius.circular(8), onTap: () => widget.onDraft(draft),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (project != null) ...[
                ProjectAvatar(project: project, size: 14, generated: session.projectAvatarStyle == 'generated'),
                const SizedBox(width: 6),
              ],
              Expanded(child: Text(project?.name ?? 'Draft', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xff9696a0)))),
              const Icon(Icons.edit_outlined, size: 13, color: opencodeFaint),
              const SizedBox(width: 4),
              const Text('Draft', style: TextStyle(fontSize: 11, color: opencodeFaint)),
            ]),
            const SizedBox(height: 4),
            Text(text.isEmpty ? '$count attachment${count == 1 ? '' : 's'}' : text,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, height: 20 / 14)),
          ]))));
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _sidebarTasks(session, widget.projectKey);
    final pins = session.pinnedTaskIds.toSet();
    final pinned = tasks.where((entry) => pins.contains(entry.$2.id)).toList();
    final working = tasks.where((entry) => entry.$2.running && !pins.contains(entry.$2.id)).toList();
    final drafts = _sidebarDrafts(session, widget.projectKey);
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return Material(color: const Color(0xfff8f8f9), child: DecoratedBox(
      decoration: const BoxDecoration(border: Border(right: BorderSide(color: Color(0xffe2e2e5)))),
      child: Column(children: [
        DesktopWindowDragRegion(child: SizedBox(height: 56, child: Padding(
          padding: EdgeInsets.only(left: widget.windowControls ? widget.titlebarInset + 40 : 48, right: 12),
          child: Row(children: [
            Flexible(child: TextButton(onPressed: widget.onHome,
              style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 28), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('Happen', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: -.4)))),
            const SizedBox(width: 6),
            _button('Go back', const Icon(Icons.arrow_back_rounded), widget.onBack),
            _button('Go forward', const Icon(Icons.arrow_forward_rounded), widget.onForward),
          ])))),
        Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), child: SizedBox(height: 32, child: Row(children: [
          Expanded(child: TextButton.icon(onPressed: widget.onSearch,
            style: TextButton.styleFrom(alignment: Alignment.centerLeft,
              foregroundColor: const Color(0xff72727f), padding: const EdgeInsets.symmetric(horizontal: 6)),
            icon: sidebarIcon(SidebarIcon.search),
            label: const Text('Search', style: TextStyle(fontSize: 14)))),
          PopupMenuButton<String>(tooltip: 'Filter by project',
            onSelected: (key) => widget.onProjectFilter(key == '*' ? null : key),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: '*', checked: widget.projectKey == null, child: const Text('All projects')),
              const PopupMenuDivider(),
              for (final project in session.projects.where((project) => !project.removing))
                CheckedPopupMenuItem(value: project.checkoutKey, checked: widget.projectKey == project.checkoutKey,
                  child: Text(project.name)),
            ],
            child: SizedBox.square(dimension: 28,
              child: Center(child: sidebarIcon(SidebarIcon.listFilter)))),
          _button('Open project', sidebarIcon(SidebarIcon.folderPlus), widget.onAddProject),
          _button('New thread (${mac ? '⌘N' : 'Ctrl+N'})', sidebarIcon(SidebarIcon.squarePen), widget.onNew),
        ]))),
        Expanded(child: Focus(onKeyEvent: (_, event) {
          if (_reordering && event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
            _pinnedList.currentState?.cancelReorder();
            setState(() => _reordering = false);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        }, child: DragBoundary(child: CustomScrollView(key: const PageStorageKey('thread-sidebar'), slivers: [
          SliverPadding(padding: const EdgeInsets.symmetric(horizontal: 8), sliver: SliverMainAxisGroup(slivers: [
            if (pinned.isNotEmpty) ...[
              SliverToBoxAdapter(child: _dragBoundary('Pinned')),
              SliverReorderableList(key: _pinnedList, itemCount: pinned.length,
                onReorderStart: (_) => setState(() => _reordering = true),
                onReorderEnd: (_) => setState(() => _reordering = false),
                onReorderItem: (oldIndex, newIndex) {
                  final order = pinned.map((entry) => entry.$2.id).toList();
                  order.insert(newIndex, order.removeAt(oldIndex));
                  unawaited(_run(session, () => session.reorderPinnedTasks(order)));
                },
                proxyDecorator: _dragProxy,
                itemBuilder: (context, index) {
                  final (project, task) = pinned[index];
                  return _row(project, task, reorderIndex: pinned.length > 1 ? index : null);
                }),
              SliverToBoxAdapter(child: _dragBoundary('Threads')),
            ],
            SliverList.list(children: [
              if (working.isNotEmpty) ...[
                _sectionHeading('working', 'Working', working.length),
                for (final (project, task) in working)
                  if (!session.collapsedSidebarSections.contains('working') || session.task == task) _row(project, task),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: Divider(height: 1)),
              ],
              for (final draft in drafts) _draft(draft),
              for (final (project, task) in tasks.where((entry) => !entry.$2.running && !pins.contains(entry.$2.id)))
                _row(project, task),
              const SizedBox(height: 12),
            ]),
          ])),
        ])))),
        Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), child: Row(children: [
          _button('App settings', const Icon(Icons.settings_outlined), widget.onSettings),
          const SizedBox(width: 4),
          _button('All sessions', const Icon(Icons.grid_view_outlined), widget.onHome),
          const Spacer(),
          if (!session.connected) const Padding(padding: EdgeInsets.only(right: 8),
            child: Text('Disconnected', style: TextStyle(fontSize: 11, color: opencodeFaint))),
          _button('Refresh threads', const Icon(Icons.sync_rounded), session.connected ? widget.onRefresh : null),
        ])),
      ])));
  }
}

class WorkspaceHome extends StatefulWidget {
  const WorkspaceHome({super.key, required this.session, required this.focusNode, required this.onSelect,
    required this.onNew, required this.onAddProject, required this.onArchive});
  final DesktopSession session;
  final FocusNode focusNode;
  final void Function(Project, DesktopTask) onSelect;
  final ValueChanged<Project> onNew;
  final VoidCallback onAddProject;
  final void Function(DesktopTask, bool) onArchive;
  @override
  State<WorkspaceHome> createState() => _WorkspaceHomeState();
}

class _WorkspaceHomeState extends State<WorkspaceHome> {
  final _search = TextEditingController();
  @override
  void dispose() { _search.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final pins = {for (final (index, id) in widget.session.pinnedTaskIds.indexed) id: index};
    final entries = [for (final project in widget.session.projects.where((project) => !project.removing))
      for (final task in project.tasks)
        if (!task.archived && '${task.title} ${project.name} ${project.path}'.toLowerCase().contains(query)) (project, task)]
      ..sort((a, b) {
        final pin = (pins[a.$2.id] ?? double.infinity).compareTo(pins[b.$2.id] ?? double.infinity);
        return pin != 0 ? pin : b.$2.lastActivity.compareTo(a.$2.lastActivity);
      });
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 800),
      child: Padding(padding: const EdgeInsets.fromLTRB(32, 48, 32, 24), child: Column(children: [
        Row(children: [
          const Expanded(child: Text('Threads', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500))),
          IconButton(tooltip: 'Open project', onPressed: widget.onAddProject, icon: sidebarIcon(SidebarIcon.folderPlus, size: 18)),
        ]),
        const SizedBox(height: 20),
        TextField(key: const ValueKey('session-search'), controller: _search, focusNode: widget.focusNode,
          onChanged: (_) => setState(() {}), decoration: const InputDecoration(hintText: 'Search sessions', prefixIcon: Icon(Icons.search, size: 17))),
        const SizedBox(height: 16),
        Expanded(child: ListView.builder(itemCount: entries.length, itemBuilder: (context, index) {
          final (project, task) = entries[index];
          return _ThreadRow(key: ValueKey('home-row:${task.id}'),
            session: widget.session, task: task, onArchive: widget.onArchive,
            builder: (renameInput) => SidebarHover(builder: (context, hovering) => ListTile(
              key: ValueKey('home:${task.id}'), leading: ProjectAvatar(project: project),
              title: renameInput ?? Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              subtitle: Text(project.name, style: const TextStyle(fontSize: 11, color: opencodeFaint)),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                _ThreadStatus(session: widget.session, task: task),
                if (hovering || pins.containsKey(task.id)) _pinButton(widget.session, task),
              ]), onTap: renameInput == null ? () => widget.onSelect(project, task) : null)));
        })),
      ]))));
  }
}

class _ThreadRow extends StatefulWidget {
  const _ThreadRow({super.key, required this.session, required this.task, required this.onArchive, required this.builder});
  final DesktopSession session;
  final DesktopTask task;
  final void Function(DesktopTask, bool) onArchive;
  final Widget Function(Widget? renameInput) builder;
  @override
  State<_ThreadRow> createState() => _ThreadRowState();
}

class _ThreadRowState extends State<_ThreadRow> {
  final _title = TextEditingController();
  final _renameFocus = FocusNode(debugLabel: 'Thread title');
  final _rowFocus = FocusNode(debugLabel: 'Thread row');
  final _renameLifetime = CancellationToken();
  RenameState _rename = const RenameIdle();
  bool get _renaming => _rename is RenameEditing;
  bool get _canRename => widget.session.connected && !widget.task.archiving && widget.task.sideParentID == null &&
    switch (_rename) {
      RenameIdle() || RenameFailed() => true,
      RenameEditing() || RenameSaving() => false,
    };

  void _transitionRename(RenameState next) => setState(() => _rename = transitionRename(_rename, next));

  @override
  void initState() {
    super.initState();
    _renameFocus.addListener(_onRenameFocus);
  }

  @override
  void dispose() {
    _renameLifetime.cancel();
    _renameFocus.removeListener(_onRenameFocus);
    _renameFocus.dispose();
    _rowFocus.dispose();
    _title.dispose();
    super.dispose();
  }

  void _startRename() {
    if (!_canRename) return;
    final title = switch (_rename) { RenameFailed(:final title) => title, _ => widget.task.title };
    _title.value = TextEditingValue(text: title,
      selection: TextSelection(baseOffset: 0, extentOffset: title.length));
    _transitionRename(const RenameEditing());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_renaming) return;
      _renameFocus.requestFocus();
      _title.selection = TextSelection(baseOffset: 0, extentOffset: _title.text.length);
    });
  }

  void _onRenameFocus() {
    if (!_renameFocus.hasFocus) _finishRename(cancel: true);
  }

  void _finishRename({bool cancel = false, bool restoreFocus = false}) {
    if (!mounted || !_renaming) return;
    // Settle before removing the input: Enter/Escape must not commit again on blur.
    final next = cancel ? const RenameIdle() : RenameSaving(_title.text);
    _transitionRename(next);
    if (restoreFocus) _rowFocus.requestFocus();
    if (next is RenameSaving) unawaited(_saveRename(next));
  }

  Future<void> _saveRename(RenameSaving saving) async {
    final session = widget.session;
    try {
      await session.renameTask(widget.task, saving.title, cancellation: _renameLifetime);
    } on CancelledException {
      if (mounted && identical(_rename, saving)) _transitionRename(const RenameIdle());
      return;
    } catch (failure) {
      if (mounted && identical(_rename, saving)) _transitionRename(RenameFailed(saving.title, failure));
      session.showError(failure, title: 'Failed to rename thread');
      return;
    }
    if (mounted && identical(_rename, saving)) _transitionRename(const RenameIdle());
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (_renaming) {
      if (event.logicalKey != LogicalKeyboardKey.escape || !_title.value.composing.isCollapsed) return KeyEventResult.ignored;
      _finishRename(cancel: true, restoreFocus: true);
    } else {
      if (event.logicalKey != LogicalKeyboardKey.f2 || !_canRename) return KeyEventResult.ignored;
      _startRename();
    }
    return KeyEventResult.handled;
  }

  Future<void> _showMenu(TapDownDetails details) async {
    final session = widget.session, task = widget.task;
    final pinned = session.pinnedTaskIds.contains(task.id), overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    PopupMenuItem<String> item(String value, String label, IconData icon, {required bool enabled, String? shortcut}) =>
      PopupMenuItem(value: value, enabled: enabled, height: 32, padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(children: [
          Icon(icon, size: 15, color: enabled ? conversationSecondary : conversationOutline),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          if (shortcut != null) ...[
            const SizedBox(width: 16),
            Text(shortcut, style: const TextStyle(fontSize: 11, color: conversationSecondary)),
          ],
        ]));
    final action = await showMenu<String>(context: context,
      constraints: const BoxConstraints(minWidth: 208, maxWidth: 240), menuPadding: const EdgeInsets.all(4),
      color: Colors.white, surfaceTintColor: Colors.transparent, elevation: 6, shadowColor: const Color(0x24000000),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: conversationOutline)),
      position: RelativeRect.fromRect(details.globalPosition & Size.zero, Offset.zero & overlay.size), items: [
        item('pin', pinned ? 'Unpin session' : 'Pin session', pinned ? Icons.push_pin : Icons.push_pin_outlined, enabled: !task.archiving),
        item('rename', 'Rename thread', Icons.edit_outlined, enabled: _canRename, shortcut: 'F2'),
        const PopupMenuDivider(height: 8),
        item('archive', task.archived ? 'Restore session' : 'Archive session',
          task.archived ? Icons.unarchive_outlined : Icons.archive_outlined, enabled: session.connected && !task.archiving),
      ]);
    if (!mounted) return;
    if (action == 'pin') await _run(session, () => session.pinTask(task, !pinned));
    if (action == 'rename') _startRename();
    if (action == 'archive') widget.onArchive(task, !task.archived);
  }

  @override
  Widget build(BuildContext context) {
    final renameInput = _renaming ? SizedBox(height: 26, child: Semantics(label: 'Thread title', child: TextSelectionTheme(
      data: const TextSelectionThemeData(selectionColor: Color(0xffdbe4ff), cursorColor: conversationForeground),
      child: TextField(
        key: ValueKey('thread-title:${widget.task.id}'), controller: _title, focusNode: _renameFocus, autofocus: true,
        selectAllOnFocus: true, cursorWidth: 1.5,
        style: const TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w500, color: conversationForeground),
        textAlignVertical: TextAlignVertical.center, textInputAction: TextInputAction.done,
        decoration: InputDecoration(isDense: true, filled: true, fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: const BorderSide(color: conversationOutline)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: const BorderSide(color: Color(0xffa1a1aa)))),
        onEditingComplete: () {},
        onSubmitted: (_) => _finishRename(restoreFocus: true),
        onTapOutside: (_) => _renameFocus.unfocus(),
    )))) : null;
    return Focus(focusNode: _rowFocus, onKeyEvent: _onKeyEvent, child: GestureDetector(
      key: ValueKey('thread-menu:${widget.task.id}'), onSecondaryTapDown: _showMenu,
      onDoubleTap: _canRename ? () {
        final keyboard = HardwareKeyboard.instance;
        if (!keyboard.isControlPressed && !keyboard.isMetaPressed && !keyboard.isAltPressed && !keyboard.isShiftPressed) _startRename();
      } : null,
      child: widget.builder(renameInput)));
  }
}

Widget _pinButton(DesktopSession session, DesktopTask task, {bool compact = false}) {
  final pinned = session.pinnedTaskIds.contains(task.id);
  return SidebarHover(builder: (context, hovering) => SizedBox.square(dimension: compact ? 12 : 20,
    child: IconButton(key: ValueKey('pin:${task.id}'),
    tooltip: pinned ? 'Unpin session' : 'Pin session', padding: EdgeInsets.zero,
    constraints: const BoxConstraints(),
    style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    onPressed: task.archiving || session.savingTaskPins ? null : () => unawaited(_run(session, () => session.pinTask(task, !pinned))),
    icon: sidebarIcon(pinned && hovering ? SidebarIcon.pinOff : SidebarIcon.pin,
      size: compact ? 12 : 13, color: const Color(0xffa1a1aa)))));
}

class _ThreadStatus extends StatelessWidget {
  const _ThreadStatus({required this.session, required this.task, this.showLabel = false});
  final DesktopSession session;
  final DesktopTask task;
  final bool showLabel;
  @override
  Widget build(BuildContext context) {
    final status = task.turns.values.lastOrNull?['status'];
    final needsInput = task.questions.isNotEmpty || session.sideChats.values.any((side) => side.sideParentID == task.id && side.questions.isNotEmpty);
    final interrupted = !task.running && (status == 'inProgress' || status == 'interrupted' ||
      task.projectionState['summary']?['time']?['busy'] != null && task.projectionState['summary']?['time']?['idle'] == null);
    final (label, icon, color) = needsInput ? ('Input', Icons.question_answer_outlined, const Color(0xff4f46e5))
      : task.running ? ('Working', null, const Color(0xff5876ff))
      : task.loadError != null || status == 'failed' ? ('Failed', Icons.error_outline, const Color(0xffc44848))
      : interrupted ? ('Interrupted', Icons.pause_circle_outline, const Color(0xffb67a2a))
      : session.hasUnseenCompletion(task) ? ('Done', Icons.check_circle_outline, const Color(0xff059669))
      : ('Idle', Icons.circle_outlined, opencodeFaint);
    final started = task.runStartedAt;
    final elapsed = started == null ? null : DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(started));
    final duration = elapsed == null ? '' : elapsed.inHours > 0 ? ' ${elapsed.inHours}h ${elapsed.inMinutes % 60}m'
      : elapsed.inMinutes > 0 ? ' ${elapsed.inMinutes}m' : ' <1m';
    final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(task.lastActivity));
    final time = task.lastActivity <= 0 ? '' : age.inDays > 0 ? '${age.inDays}d'
      : age.inHours > 0 ? '${age.inHours}h' : age.inMinutes > 0 ? '${age.inMinutes}m' : 'now';
    return Tooltip(message: label, child: Semantics(label: label, child: Row(mainAxisSize: MainAxisSize.min, children: [
      if (!showLabel || label != 'Idle') SizedBox.square(dimension: 14,
        child: icon == null ? ConversationActivityIndicator(color: color) : Icon(icon, size: 13, color: color)),
      if (showLabel) ...[
        const SizedBox(width: 4),
        Text(label == 'Idle' ? time : '$label${task.running && !needsInput ? duration : ''}',
          style: TextStyle(fontSize: 12, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
      ],
    ])));
  }
}

Future<void> _run(DesktopSession session, Future<void> Function() action) async {
  try { await action(); } catch (error) { session.showError(error); }
}
