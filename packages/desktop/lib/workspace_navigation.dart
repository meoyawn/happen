import 'dart:async';

import 'package:flutter/material.dart';

import 'appearance.dart';
import 'conversation_indicator.dart';
import 'project_avatar.dart';
import 'session.dart';
import 'sidebar_hover.dart';
import 'window_chrome.dart';

// T3Code Sidebar + SidebarProjectFolderHeader + SidebarThreadRow: one project
// tree, pinned threads, compact status rows and a persistent connection footer.
List<(Project, DesktopTask)> sidebarThreads(DesktopSession session) => [
  ...session.pinnedTasks.where((entry) => !session.collapsedSidebarSections.contains('pinned') || session.task == entry.$2),
  for (final project in session.projects.where((project) => !project.removing))
    ..._projectThreads(session, project).where((task) =>
      !session.collapsedSidebarSections.contains('project:${project.checkoutKey}') || session.task == task)
      .map((task) => (project, task)),
];

List<DesktopTask> _projectThreads(DesktopSession session, Project project) =>
  project.tasks.where((task) => !task.archived && !session.pinnedTaskIds.contains(task.id)).toList()
    ..sort((a, b) => b.lastActivity.compareTo(a.lastActivity));

class ThreadSidebar extends StatelessWidget {
  const ThreadSidebar({super.key, required this.session, required this.home, required this.windowControls,
    required this.onHome, required this.onSearch, required this.onNew, required this.onSettings,
    required this.onSelect, required this.onArchive, required this.onDraft});
  final DesktopSession session;
  final bool home, windowControls;
  final VoidCallback onHome, onSearch, onNew, onSettings;
  final void Function(Project, DesktopTask) onSelect;
  final void Function(DesktopTask, bool) onArchive;
  final ValueChanged<SessionDraft> onDraft;

  Widget _heading(String title, String section, {Widget? leading, int? count}) {
    final expanded = !session.collapsedSidebarSections.contains(section);
    return InkWell(onTap: () => unawaited(_run(session, () => session.chooseSidebarSection(section, expanded))),
      borderRadius: BorderRadius.circular(5), child: SizedBox(height: 30, child: Row(children: [
        Icon(expanded ? Icons.keyboard_arrow_down_rounded : Icons.chevron_right_rounded, size: 14, color: opencodeFaint),
        if (leading != null) ...[const SizedBox(width: 4), leading],
        const SizedBox(width: 6),
        Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: opencodeMuted))),
        if (count != null) Text('$count', style: const TextStyle(fontSize: 11, color: opencodeFaint)),
        const SizedBox(width: 8),
      ])));
  }

  Widget _row(BuildContext context, Project project, DesktopTask task) => _threadMenu(context, session, task, onArchive,
    child: SidebarHover(builder: (context, hovering) {
      final selected = !home && session.task == task;
      return Material(color: selected ? opencodeLayer : Colors.transparent, borderRadius: BorderRadius.circular(6),
        child: InkWell(key: ValueKey('thread:${task.id}'), borderRadius: BorderRadius.circular(6),
          onTap: () => onSelect(project, task), child: Padding(padding: const EdgeInsets.fromLTRB(12, 7, 6, 7),
            child: Row(children: [
              _ThreadStatus(session: session, task: task), const SizedBox(width: 8),
              Expanded(child: Tooltip(message: '${task.title}\n${project.path}', child: Text(task.title,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12,
                  color: selected || task.lastActivity > (session.viewedTasks[task.id] ?? -1) ? opencodeInk : opencodeMuted)))),
              if (hovering || session.pinnedTaskIds.contains(task.id)) _pinButton(session, task),
              if (hovering) SizedBox.square(dimension: 20, child: IconButton(tooltip: 'Archive session',
                padding: EdgeInsets.zero, onPressed: session.connected && !task.archiving && !project.removing
                  ? () => onArchive(task, true) : null,
                icon: const Icon(Icons.archive_outlined, size: 14, color: opencodeFaint))),
            ]))));
    }));

  @override
  Widget build(BuildContext context) => Material(color: const Color(0xfffafafa), child: Column(children: [
    DesktopWindowDragRegion(child: SizedBox(height: windowControls ? 48 : 16, width: double.infinity)),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
      TextButton.icon(onPressed: onNew, icon: const Icon(Icons.edit_square, size: 15), label: const Text('New thread', style: TextStyle(fontSize: 12))),
      const Spacer(),
      IconButton(tooltip: 'Search sessions', onPressed: onSearch, icon: const Icon(Icons.search_rounded, size: 17)),
    ])),
    Expanded(child: ListView(key: const PageStorageKey('thread-sidebar'), padding: const EdgeInsets.fromLTRB(10, 8, 10, 12), children: [
      if (session.pinnedTasks.isNotEmpty) ...[
        _heading('Pinned', 'pinned', leading: const Icon(Icons.push_pin_outlined, size: 13, color: opencodeFaint)),
        for (final (project, task) in session.pinnedTasks)
          if (!session.collapsedSidebarSections.contains('pinned') || session.task == task) _row(context, project, task),
        const SizedBox(height: 12),
      ],
      for (final project in session.projects.where((project) => !project.removing)) ...[
        _heading(project.name, 'project:${project.checkoutKey}', count: _projectThreads(session, project).length,
          leading: ProjectAvatar(project: project, size: 14, generated: session.projectAvatarStyle == 'generated')),
        if (!session.collapsedSidebarSections.contains('project:${project.checkoutKey}'))
          for (final draft in session.sessionDrafts.where((draft) => draft.checkoutKey == project.checkoutKey))
            ListTile(key: ValueKey('draft:${draft.id}'), dense: true, visualDensity: VisualDensity.compact,
              leading: const Icon(Icons.edit_outlined, size: 14), title: const Text('New session', style: TextStyle(fontSize: 12)),
              selected: !home && session.task == null && session.currentDraft == draft, onTap: () => onDraft(draft)),
        for (final task in _projectThreads(session, project))
          if (!session.collapsedSidebarSections.contains('project:${project.checkoutKey}') || session.task == task) _row(context, project, task),
        const SizedBox(height: 12),
      ],
      if (session.projects.isEmpty) const Padding(padding: EdgeInsets.all(12),
        child: Text('Open a project to start a thread.', style: TextStyle(fontSize: 12, color: opencodeFaint))),
    ])),
    const Divider(height: 1),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Row(children: [
      Icon(Icons.circle, size: 6, color: session.connected ? const Color(0xff5a9c77) : Colors.orange),
      const SizedBox(width: 7), Text(session.connected ? 'Local' : 'Disconnected', style: const TextStyle(fontSize: 11, color: opencodeFaint)),
      const Spacer(),
      IconButton(tooltip: 'All sessions', onPressed: onHome, icon: const Icon(Icons.grid_view_outlined, size: 16)),
      IconButton(tooltip: 'App settings', onPressed: onSettings, icon: const Icon(Icons.settings_outlined, size: 16)),
    ])),
  ]));
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
  const _ThreadStatus({required this.session, required this.task});
  final DesktopSession session;
  final DesktopTask task;
  @override
  Widget build(BuildContext context) {
    final status = task.turns.values.lastOrNull?['status'];
    final needsInput = task.questions.isNotEmpty || session.sideChats.values.any((side) => side.sideParentID == task.id && side.questions.isNotEmpty);
    final interrupted = !task.running && (status == 'inProgress' || status == 'interrupted' ||
      task.projectionState['summary']?['time']?['busy'] != null && task.projectionState['summary']?['time']?['idle'] == null);
    final (label, icon, color) = needsInput ? ('Input', Icons.question_answer_outlined, const Color(0xff4f46e5))
      : task.running ? ('Working', null, const Color(0xff2872b5))
      : task.loadError != null || status == 'failed' ? ('Failed', Icons.error_outline, const Color(0xffc44848))
      : interrupted ? ('Interrupted', Icons.pause_circle_outline, const Color(0xffb67a2a))
      : ('Idle', Icons.circle_outlined, opencodeFaint);
    return Tooltip(message: label, child: Semantics(label: label, child: SizedBox.square(dimension: 14,
      child: icon == null ? ConversationActivityIndicator(color: color) : Icon(icon, size: 13, color: color))));
  }
}

Future<void> _run(DesktopSession session, Future<void> Function() action) async {
  try { await action(); } catch (error) { session.showError(error); }
}
