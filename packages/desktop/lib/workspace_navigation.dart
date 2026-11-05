import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'appearance.dart';
import 'conversation_indicator.dart';
import 'project_avatar.dart';
import 'provider_icon.dart';
import 'session.dart';
import 'sidebar_hover.dart';
import 'window_chrome.dart';

List<(Project, DesktopTask)> _sidebarTasks(DesktopSession session, String? projectKey) {
  final pins = {for (final (index, id) in session.pinnedTaskIds.indexed) id: index};
  return [
    for (final project in session.projects)
      if (!project.removing && (projectKey == null || project.checkoutKey == projectKey))
        for (final task in project.tasks)
          if (!task.archived) (project, task),
  ]..sort((a, b) {
    if (a.$2.running != b.$2.running) return a.$2.running ? -1 : 1;
    final pin = (pins[a.$2.id] ?? double.infinity).compareTo(pins[b.$2.id] ?? double.infinity);
    if (pin != 0) return pin;
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
  return [
    for (final (_, task) in tasks.where((entry) => entry.$2.running))
      if (!session.collapsedSidebarSections.contains('working') || session.task == task) task.id,
    for (final draft in _sidebarDrafts(session, projectKey)) draft.id,
    for (final (_, task) in tasks.where((entry) => !entry.$2.running)) task.id,
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

  @override
  void initState() {
    super.initState();
    _clock = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() { _clock?.cancel(); super.dispose(); }

  Widget _button(String tooltip, IconData icon, VoidCallback? onPressed) => IconButton(
    tooltip: tooltip, onPressed: onPressed,
    style: IconButton.styleFrom(minimumSize: const Size.square(28), maximumSize: const Size.square(28),
      padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
    icon: Icon(icon, size: 16, color: onPressed == null ? const Color(0xffb5b5bd) : const Color(0xff7c7c89)));

  Widget _workingHeading(int count) {
    final expanded = !session.collapsedSidebarSections.contains('working');
    return InkWell(key: const ValueKey('working-section'),
      onTap: () => unawaited(_run(session, () => session.chooseSidebarSection('working', expanded))),
      borderRadius: BorderRadius.circular(6), child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: Row(children: [
          const Expanded(child: Text('Working', style: TextStyle(fontSize: 12, color: Color(0xff72727f)))),
          Text('$count', style: const TextStyle(fontSize: 12, color: Color(0xff9696a0))),
          const SizedBox(width: 8),
          Icon(expanded ? Icons.keyboard_arrow_down_rounded : Icons.chevron_right_rounded, size: 14, color: opencodeFaint),
        ])));
  }

  Widget _row(BuildContext context, Project project, DesktopTask task) => _threadMenu(context, session, task, widget.onArchive,
    child: SidebarHover(builder: (context, hovering) {
      final selected = !widget.home && session.task == task;
      return Material(color: selected ? const Color(0xffeeeef0) : Colors.transparent, borderRadius: BorderRadius.circular(8),
        child: InkWell(key: ValueKey('thread:${task.id}'), borderRadius: BorderRadius.circular(8),
          onTap: () => widget.onSelect(project, task), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(height: 20, child: Row(children: [
                ProjectAvatar(project: project, size: 14, generated: session.projectAvatarStyle == 'generated'),
                const SizedBox(width: 6),
                Expanded(child: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Color(0xff9696a0)))),
                if (hovering) ...[
                  _pinButton(session, task),
                  SizedBox.square(dimension: 22, child: IconButton(tooltip: 'Archive session',
                    padding: EdgeInsets.zero, onPressed: session.connected && !task.archiving
                      ? () => widget.onArchive(task, true) : null,
                    icon: const Icon(Icons.archive_outlined, size: 14, color: opencodeFaint))),
                ] else ...[
                  if (session.pinnedTaskIds.contains(task.id)) const Padding(padding: EdgeInsets.only(right: 6),
                    child: Icon(Icons.push_pin_outlined, size: 12, color: opencodeFaint)),
                  _ThreadStatus(session: session, task: task, showLabel: true),
                ],
              ])),
              const SizedBox(height: 2),
              Tooltip(message: task.title, child: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, height: 20 / 14,
                  color: selected || task.lastActivity > (session.viewedTasks[task.id] ?? -1) ? opencodeInk : opencodeFaint))),
              const SizedBox(height: 2),
              SizedBox(height: 16, child: Row(children: [
                if (project.branch case final branch?) Expanded(child: Text(branch, maxLines: 1,
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Color(0xff9696a0))))
                else const Spacer(),
                if (task.provider != null) Tooltip(message: '${task.provider}${task.model == null ? '' : ' · ${task.model}'}',
                  child: providerIcon(task.provider, size: 13, color: const Color(0xffb1b1ba))),
              ])),
            ]))));
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
    final working = tasks.where((entry) => entry.$2.running).toList();
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
            _button('Go back', Icons.arrow_back_rounded, widget.onBack),
            _button('Go forward', Icons.arrow_forward_rounded, widget.onForward),
          ])))),
        Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), child: SizedBox(height: 32, child: Row(children: [
          Expanded(child: TextButton.icon(onPressed: widget.onSearch,
            style: TextButton.styleFrom(alignment: Alignment.centerLeft,
              foregroundColor: const Color(0xff72727f), padding: const EdgeInsets.symmetric(horizontal: 6)),
            icon: const Icon(Icons.search_rounded, size: 18),
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
            child: const SizedBox.square(dimension: 28,
              child: Icon(Icons.filter_list_rounded, size: 18, color: Color(0xff7c7c89)))),
          _button('Open project', Icons.create_new_folder_outlined, widget.onAddProject),
          _button('New thread (${mac ? '⌘N' : 'Ctrl+N'})', Icons.edit_square, widget.onNew),
        ]))),
        Expanded(child: ListView(key: const PageStorageKey('thread-sidebar'),
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12), children: [
            if (working.isNotEmpty) ...[
              _workingHeading(working.length),
              for (final (project, task) in working)
                if (!session.collapsedSidebarSections.contains('working') || session.task == task) _row(context, project, task),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: Divider(height: 1)),
            ],
            for (final draft in drafts) _draft(draft),
            for (final (project, task) in tasks.where((entry) => !entry.$2.running)) _row(context, project, task),
          ])),
        Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 12), child: Row(children: [
          _button('App settings', Icons.settings_outlined, widget.onSettings),
          const SizedBox(width: 4),
          _button('All sessions', Icons.grid_view_outlined, widget.onHome),
          const Spacer(),
          if (!session.connected) const Padding(padding: EdgeInsets.only(right: 8),
            child: Text('Disconnected', style: TextStyle(fontSize: 11, color: opencodeFaint))),
          _button('Refresh threads', Icons.sync_rounded, session.connected ? widget.onRefresh : null),
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
          IconButton(tooltip: 'Open project', onPressed: widget.onAddProject, icon: const Icon(Icons.create_new_folder_outlined, size: 18)),
        ]),
        const SizedBox(height: 20),
        TextField(key: const ValueKey('session-search'), controller: _search, focusNode: widget.focusNode,
          onChanged: (_) => setState(() {}), decoration: const InputDecoration(hintText: 'Search sessions', prefixIcon: Icon(Icons.search, size: 17))),
        const SizedBox(height: 16),
        Expanded(child: ListView.builder(itemCount: entries.length, itemBuilder: (context, index) {
          final (project, task) = entries[index];
          return _threadMenu(context, widget.session, task, widget.onArchive, child: SidebarHover(builder: (context, hovering) => ListTile(
            key: ValueKey('home:${task.id}'), leading: ProjectAvatar(project: project),
            title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
            subtitle: Text(project.name, style: const TextStyle(fontSize: 11, color: opencodeFaint)),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              _ThreadStatus(session: widget.session, task: task),
              if (hovering || pins.containsKey(task.id)) _pinButton(widget.session, task),
            ]), onTap: () => widget.onSelect(project, task))));
        })),
      ]))));
  }
}

Widget _threadMenu(BuildContext context, DesktopSession session, DesktopTask task,
    void Function(DesktopTask, bool) onArchive, {required Widget child}) => GestureDetector(
  key: ValueKey('thread-menu:${task.id}'),
  onSecondaryTapDown: (details) async {
    final pinned = session.pinnedTaskIds.contains(task.id), overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(context: context,
      position: RelativeRect.fromRect(details.globalPosition & Size.zero, Offset.zero & overlay.size), items: [
        PopupMenuItem(value: 'pin', enabled: !task.archiving, child: Text(pinned ? 'Unpin session' : 'Pin session')),
        PopupMenuItem(value: 'archive', enabled: session.connected && !task.archiving, child: Text(task.archived ? 'Restore session' : 'Archive session')),
      ]);
    if (action == 'pin') await _run(session, () => session.pinTask(task, !pinned));
    if (action == 'archive') onArchive(task, !task.archived);
  }, child: child);

Widget _pinButton(DesktopSession session, DesktopTask task) {
  final pinned = session.pinnedTaskIds.contains(task.id);
  return SizedBox.square(dimension: 20, child: IconButton(key: ValueKey('pin:${task.id}'),
    tooltip: pinned ? 'Unpin session' : 'Pin session', padding: EdgeInsets.zero,
    onPressed: task.archiving ? null : () => unawaited(_run(session, () => session.pinTask(task, !pinned))),
    icon: Icon(pinned ? Icons.push_pin : Icons.push_pin_outlined, size: 13, color: opencodeFaint)));
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
