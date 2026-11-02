import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'appearance.dart';
import 'opencode_activity.dart';
import 'session.dart';
import 'project_avatar.dart';
import 'sidebar_hover.dart';
import 'window_chrome.dart';

({List<(Project, DesktopTask)> pinned, List<(Project, DesktopTask)> working, List<(Project, DesktopTask)> needs,
  List<(Project, DesktopTask)> recent})
inboxSections(DesktopSession session) {
  final entries = [for (final project in session.projects) if (!project.removing)
    for (final task in project.tasks)
      if (!task.archived && !session.pinnedTaskIds.contains(task.id)) (project, task)]
    ..sort((a, b) => b.$2.lastActivity.compareTo(a.$2.lastActivity));
  final needs = entries.where((entry) =>
    {'failed', 'interrupted'}.contains(_taskStatus(session, entry.$2))).toList();
  // OpenCode's inbox-working.ts: oldest run first; live steps never move rows.
  final working = entries.where((entry) => entry.$2.running).toList()
    ..sort((a, b) {
      final start = (a.$2.runStartedAt ?? double.infinity).compareTo(b.$2.runStartedAt ?? double.infinity);
      return start != 0 ? start : a.$2.id.compareTo(b.$2.id);
    });
  final recent = entries.where((entry) => !entry.$2.running && !needs.contains(entry) &&
    _finishedAt(entry.$2) >= (session.inboxSince ?? 0)).toList()
    ..sort((a, b) => _finishedAt(b.$2).compareTo(_finishedAt(a.$2)));
  return (pinned: session.pinnedTasks, working: working, needs: needs, recent: recent);
}

// OpenCode: app/src/shell/titlebar/{titlebar,tab-nav,inbox}.tsx.
class OpenCodeSidebar extends StatelessWidget {
  const OpenCodeSidebar({super.key, required this.session, required this.home,
    required this.windowControls,
    required this.onHome, required this.onSearch, required this.onNew, required this.onSettings,
    required this.onSelect, required this.onArchive, required this.onDraft});
  final DesktopSession session;
  final bool home;
  final bool windowControls;
  final VoidCallback onHome, onSearch, onNew, onSettings;
  final void Function(Project, DesktopTask) onSelect;
  final void Function(DesktopTask, bool) onArchive;
  final ValueChanged<SessionDraft> onDraft;

  @override
  Widget build(BuildContext context) => ConversationTypography(    child: Material(color: const Color(0xfff9f9f9), child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 10, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (windowControls) ...[
          const DesktopWindowDragRegion(child: SizedBox(height: 56, width: double.infinity)),
          _navigationItem('Home', Icons.grid_view_outlined, onHome, selected: home),
        ] else
          DesktopWindowDragRegion(child: Padding(padding: const EdgeInsets.only(top: 18, bottom: 4, right: 32),
            child: _navigationItem('Home', Icons.grid_view_outlined, onHome, selected: home))),
        const SizedBox(height: 4),
        _navigationItem('Search sessions', Icons.search, onSearch),
        const SizedBox(height: 4),
        _navigationItem('New session', Icons.edit_square, onNew),
        const SizedBox(height: 16),
        Expanded(child: session.openCodeLayout == OpenCodeLayout.inbox
          ? _inbox(context)
          : Column(children: [
              Expanded(child: OpenCodeTabStrip(session: session, vertical: true, home: home,
                onSelect: onSelect, onArchive: onArchive, onDraft: onDraft)),
            ])),
        const SizedBox(height: 8),
        Row(children: [
          Icon(Icons.circle, size: 6, color: session.connected ? const Color(0xff5a9c77) : Colors.orange),
          const SizedBox(width: 7),
          Text(session.connected ? 'Local' : 'Disconnected', style: const TextStyle(fontSize: 12, color: opencodeFaint)),
          const Spacer(),
          IconButton(tooltip: 'App settings', onPressed: onSettings, visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.settings_outlined, size: 16, color: opencodeFaint)),
        ]),
      ]),
    )));

  Widget _navigationItem(String title, IconData icon, VoidCallback onTap, {bool selected = false}) =>
      _navigationButton(title, icon, onTap, selected: selected);

  Widget _inbox(BuildContext context) {
    final (:pinned, :working, :needs, :recent) = inboxSections(session);
    final pinnedExpanded = !session.collapsedSidebarSections.contains('pinned');
    return _InboxList(children: [
      if (pinned.isNotEmpty) ...[
        _inboxHeading('Pinned', count: pinned.length, expanded: pinnedExpanded,
          onTap: () => unawaited(_navigationRun(session, () => session.chooseSidebarSection('pinned', pinnedExpanded)))),
        for (final (project, task) in pinned)
          if (pinnedExpanded || !home && session.task == task) _inboxRow(context, project, task),
        const SizedBox(height: 12),
      ],
      if (working.isNotEmpty) ...[
        _inboxHeading('Working', count: working.length, expanded: session.inboxWorkingExpanded,
          onTap: () => unawaited(_navigationRun(session, () => session.chooseInboxWorkingExpanded(!session.inboxWorkingExpanded)))),
        for (final (project, task) in working)
          if (session.inboxWorkingExpanded || !home && session.task == task) _inboxRow(context, project, task),
        const SizedBox(height: 12),
      ],
      for (final id in session.openTabIds)
        for (final draft in session.sessionDrafts) if (draft.id == id)
          Padding(padding: const EdgeInsets.only(bottom: 4), child: SizedBox(height: 45,
            child: _draftTab(session, draft, vertical: true, home: home, onTap: () => onDraft(draft)))),
      if (needs.isNotEmpty) ...[
        _inboxHeading('Needs attention', count: needs.length),
        for (final (project, task) in needs) _inboxRow(context, project, task),
      ],
      if (recent.isNotEmpty) ...[
        if (pinned.isNotEmpty || working.isNotEmpty || needs.isNotEmpty) _inboxHeading('Recent'),
        for (final (project, task) in recent) _inboxRow(context, project, task),
      ],
      if (pinned.isEmpty && needs.isEmpty && recent.isEmpty && working.isEmpty && session.sessionDrafts.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 24, horizontal: 6),
          child: Text('No sessions in your inbox yet.', style: TextStyle(fontSize: 12, color: opencodeFaint))),
    ]);
  }

  Widget _inboxHeading(String label, {int? count, bool? expanded, VoidCallback? onTap}) =>
    Semantics(button: onTap != null, expanded: expanded,
      child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(6), child: SizedBox(height: 24,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Row(children: [
          Expanded(child: Row(children: [
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500, color: opencodeMuted))),
            if (count != null) ...[
              const SizedBox(width: 6),
              Text('$count', style: const TextStyle(fontSize: 12, height: 16 / 12, color: opencodeFaint)),
            ],
          ])),
          if (expanded != null) ...[
            const SizedBox(width: 6),
            Icon(expanded ? Icons.keyboard_arrow_down : Icons.chevron_right, size: 14, color: opencodeFaint),
          ],
        ])))));

  Widget _inboxRow(BuildContext context, Project project, DesktopTask task) {
    final status = _taskStatus(session, task);
    final pinned = session.pinnedTaskIds.contains(task.id);
    final selected = !home && session.task == task;
    return Padding(padding: const EdgeInsets.only(bottom: 4), child: _taskMenu(context, session, task, onArchive,
      child: SidebarHover(builder: (context, active) => Material(
        color: selected ? opencodeLayer : Colors.transparent, borderRadius: BorderRadius.circular(6),
        child: InkWell(key: ValueKey('inbox:${task.id}'), borderRadius: BorderRadius.circular(6),
          onTap: () => onSelect(project, task),
          child: Padding(padding: const EdgeInsets.all(6), child: LayoutBuilder(builder: (context, constraints) =>
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(height: 20, child: Row(children: [
                ProjectAvatar(project: project, generated: session.projectAvatarStyle == 'generated'), const SizedBox(width: 6),
                Expanded(child: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, height: 16 / 12, color: opencodeFaint))),
                const SizedBox(width: 6),
                _taskStatusIndicator(task, status, compact: constraints.maxWidth < 200),
                if (pinned || active || task.archiving) ...[
                  const SizedBox(width: 4),
                  _taskPinButton(session, task),
                ],
                if (active || task.archiving)
                  SizedBox(width: 20, height: 16, child: IconButton(
                    tooltip: 'Archive session', padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    onPressed: session.connected && !task.archiving && !project.removing ? () => onArchive(task, true) : null,
                    icon: SvgPicture.string(_archiveSvg, width: 14, height: 14,
                      colorFilter: const ColorFilter.mode(opencodeFaint, BlendMode.srcIn)))),
              ])),
              const SizedBox(height: 2),
              Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: _taskTitleStyle(status, selected: selected)),
              if (project.branch case final branch?) ...[
                const SizedBox(height: 2),
                Tooltip(message: project.path, child: Row(children: [
                  const Icon(Icons.fork_right, size: 12, color: opencodeFaint), const SizedBox(width: 4),
                  Expanded(child: Text(branch, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, height: 16 / 12, color: opencodeFaint))),
                ])),
              ],
            ]))),
        ),
      )),
    ));
  }
}

class _InboxList extends StatefulWidget {
  const _InboxList({required this.children});
  final List<Widget> children;

  @override
  State<_InboxList> createState() => _InboxListState();
}

class _InboxListState extends State<_InboxList> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SidebarHover(builder: (context, active) => ScrollbarTheme(
    data: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(4), radius: const Radius.circular(2),
      crossAxisMargin: 2, mainAxisMargin: 4, minThumbLength: 32,
      thumbColor: WidgetStateProperty.resolveWith((states) =>
        states.contains(WidgetState.hovered) || states.contains(WidgetState.dragged)
          ? const Color(0x33000000) : opencodeBorder),
    ),
    child: ScrollConfiguration(behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: Scrollbar(controller: _scroll, thumbVisibility: active, interactive: true,
        child: ListView(controller: _scroll, primary: false,
          // Reserve OpenCode's 8 px gutter outside the rows and their actions.
          padding: const EdgeInsets.only(right: 8), children: widget.children))),
  ));
}

// OpenCode: ui/src/icons/catalog.ts, archive (16 × 16).
const _archiveSvg = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none">
<path d="M13.1112 13.5555V14.0555H13.6112V13.5555H13.1112ZM2.889 13.5555H2.389L2.389 14.0555H2.889V13.5555ZM3.38901 5.55546L3.38901 5.05546L2.38901 5.05546L2.38901 5.55546L2.88901 5.55546L3.38901 5.55546ZM14.4446 2.44434H14.9446V1.94434L14.4446 1.94434L14.4446 2.44434ZM14.4446 5.55545L14.4446 6.05545L14.9446 6.05545V5.55545H14.4446ZM1.55566 5.55546L1.05566 5.55545L1.05566 6.05546L1.55566 6.05546L1.55566 5.55546ZM1.5557 2.44436L1.5557 1.94436L1.05571 1.94436L1.0557 2.44435L1.5557 2.44436ZM13.1112 5.55546H12.6112V13.5555H13.1112H13.6112V5.55546H13.1112ZM2.889 13.5555H3.389L3.38901 5.55546L2.88901 5.55546L2.38901 5.55546L2.389 13.5555H2.889ZM14.4446 2.44434H13.9446V5.55545H14.4446H14.9446V2.44434H14.4446ZM1.55566 5.55546L2.05566 5.55547L2.0557 2.44436L1.5557 2.44436L1.0557 2.44435L1.05566 5.55545L1.55566 5.55546ZM6.22234 8.22213V8.72213H9.7779V8.22213V7.72213H6.22234V8.22213ZM13.1112 13.5555V13.0555H2.889V13.5555V14.0555H13.1112V13.5555ZM1.5557 2.44436L1.5557 2.94436L14.4446 2.94434L14.4446 2.44434L14.4446 1.94434L1.5557 1.94436L1.5557 2.44436ZM14.4446 5.55545L14.4446 5.05545L1.55566 5.05546L1.55566 5.55546L1.55566 6.05546L14.4446 6.05545L14.4446 5.55545Z" fill="currentColor"/>
</svg>''';

class OpenCodeTopBar extends StatelessWidget {
  const OpenCodeTopBar({super.key, required this.session, required this.home,
    required this.leadingInset,
    required this.onHome, required this.onSearch, required this.onNew, required this.onSettings,
    required this.onSelect, required this.onArchive, required this.onDraft});
  final DesktopSession session;
  final bool home;
  final double leadingInset;
  final VoidCallback onHome, onSearch, onNew, onSettings;
  final void Function(Project, DesktopTask) onSelect;
  final void Function(DesktopTask, bool) onArchive;
  final ValueChanged<SessionDraft> onDraft;

  @override
  Widget build(BuildContext context) => DesktopWindowDragRegion(
    child: SizedBox(key: const ValueKey('opencode-top-tabs'), height: 44,
    child: Row(children: [
      SizedBox(width: leadingInset == 0 ? 8 : leadingInset),
      IconButton(tooltip: 'Home', onPressed: onHome, visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.grid_view_outlined, size: 16)),
      IconButton(tooltip: 'Search sessions', onPressed: onSearch, visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.search, size: 16)),
      Expanded(child: OpenCodeTabStrip(session: session, vertical: false, home: home,
        onSelect: onSelect, onArchive: onArchive, onDraft: onDraft)),
      IconButton(tooltip: 'New session', onPressed: onNew, visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.add, size: 17)),
      IconButton(tooltip: 'App settings', onPressed: onSettings, visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.settings_outlined, size: 16)),
      const SizedBox(width: 8),
    ])));
}

class OpenCodeTabStrip extends StatelessWidget {
  const OpenCodeTabStrip({super.key, required this.session, required this.vertical, required this.home,
    required this.onSelect, required this.onArchive, required this.onDraft});
  final DesktopSession session;
  final bool vertical, home;
  final void Function(Project, DesktopTask) onSelect;
  final void Function(DesktopTask, bool) onArchive;
  final ValueChanged<SessionDraft> onDraft;

  @override
  Widget build(BuildContext context) {
    final tasks = session.openTasks;
    final tabs = [for (final id in session.navigationTabIds) ...[
      for (final draft in session.sessionDrafts) if (draft.id == id)
        (id: id, project: session.projects.where((project) => project.checkoutKey == draft.checkoutKey).firstOrNull,
          task: null, draft: draft),
      for (final (project, task) in tasks) if (task.id == id)
        (id: id, project: project, task: task, draft: null),
    ]];
    return LayoutBuilder(builder: (context, constraints) => ReorderableListView.builder(
      key: ValueKey('opencode-tabs:${vertical ? 'side' : 'top'}'),
      scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
      buildDefaultDragHandles: false, padding: EdgeInsets.zero,
      itemExtent: vertical ? 49 : (constraints.maxWidth / math.max(1, tabs.length)).clamp(112.0, 220.0),
      itemCount: tabs.length,
      proxyDecorator: (child, _, animation) => Material(color: const Color(0xfff9f9f9), borderRadius: BorderRadius.circular(6), child: child),
      onReorderItem: (oldIndex, newIndex) {
        final ids = tabs.map((entry) => entry.id).toList();
        ids.insert(newIndex, ids.removeAt(oldIndex));
        ids.addAll(session.openTabIds.where((id) => !ids.contains(id)));
        unawaited(_navigationRun(session, () => session.reorderTabs(ids)));
      },
      itemBuilder: (context, index) {
        final tab = tabs[index];
        if (tab.draft case final draft?) {
          return ReorderableDragStartListener(key: ValueKey('opencode-tab:${draft.id}'), index: index,
            child: Padding(padding: vertical ? const EdgeInsets.only(bottom: 4) : const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
              child: _draftTab(session, draft, vertical: vertical, home: home, onTap: () => onDraft(draft))));
        }
        final project = tab.project!, task = tab.task!;
        final status = _taskStatus(session, task);
        final selected = !home && session.task == task;
        return ReorderableDragStartListener(key: ValueKey('opencode-tab:${task.id}'), index: index,
          child: Padding(padding: vertical ? const EdgeInsets.only(bottom: 4) : const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
            child: _taskMenu(context, session, task, onArchive, child: SidebarHover(builder: (context, active) => Material(
              color: selected ? opencodeLayer : Colors.transparent, borderRadius: BorderRadius.circular(6),
              child: InkWell(borderRadius: BorderRadius.circular(6), onTap: () => onSelect(project, task),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Row(children: [
                  ProjectAvatar(project: project, generated: session.projectAvatarStyle == 'generated'), const SizedBox(width: 6),
                  Expanded(child: Tooltip(message: '${task.title}\n${project.path}', child: Column(
                    mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: _taskTitleStyle(status, selected: selected)),
                      if (vertical) Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, height: 16 / 12, color: opencodeMuted)),
                    ]))),
                  const SizedBox(width: 4),
                  _taskStatusIndicator(task, status, compact: true),
                  if (active || session.pinnedTaskIds.contains(task.id)) _taskPinButton(session, task),
                  SizedBox(width: 20, height: 20, child: Visibility(
                    visible: active, maintainSize: true, maintainAnimation: true, maintainState: true,
                    child: IconButton(tooltip: 'Close tab', padding: EdgeInsets.zero,
                        style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        onPressed: () => unawaited(_navigationRun(session, () => session.closeTab(task))),
                        icon: const Icon(Icons.close, size: 14, color: opencodeFaint)))),
                ])),
              ),
            ))),
          ));
      },
    ));
  }
}

class OpenCodeHome extends StatefulWidget {
  const OpenCodeHome({super.key, required this.session, required this.focusNode,
    required this.onSelect, required this.onNew, required this.onAddProject, required this.onArchive});
  final DesktopSession session;
  final FocusNode focusNode;
  final void Function(Project, DesktopTask) onSelect;
  final ValueChanged<Project> onNew;
  final VoidCallback onAddProject;
  final void Function(DesktopTask, bool) onArchive;

  @override
  State<OpenCodeHome> createState() => _OpenCodeHomeState();
}

class _OpenCodeHomeState extends State<OpenCodeHome> {
  final _search = TextEditingController();

  @override
  void dispose() { _search.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.toLowerCase().trim();
    final pins = {for (var index = 0; index < widget.session.pinnedTaskIds.length; index++)
      widget.session.pinnedTaskIds[index]: index};
    final entries = [for (final project in widget.session.projects) if (!project.removing)
      for (final task in project.tasks)
        if (!task.archived && '${task.title} ${project.name} ${project.path}'.toLowerCase().contains(query)) (project, task)]
      ..sort((a, b) {
        final pin = (pins[a.$2.id] ?? double.infinity).compareTo(pins[b.$2.id] ?? double.infinity);
        return pin != 0 ? pin : b.$2.lastActivity.compareTo(a.$2.lastActivity);
      });
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: opencodeSessionWidth),
      child: Padding(padding: const EdgeInsets.fromLTRB(32, 56, 32, 24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(child: Text('Sessions', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w500, color: opencodeInk))),
          PopupMenuButton<Project>(tooltip: 'New session', onSelected: widget.onNew,
            itemBuilder: (_) => [for (final project in widget.session.projects)
              if (project.available && !project.removing) PopupMenuItem(value: project, child: Text(project.name))],
            child: const Padding(padding: EdgeInsets.all(8), child: Row(mainAxisSize: MainAxisSize.min,
              children: [Icon(Icons.add, size: 16), SizedBox(width: 6), Text('New session', style: TextStyle(fontSize: 13))]))),
          IconButton(tooltip: 'Open project', onPressed: widget.onAddProject, icon: const Icon(Icons.create_new_folder_outlined, size: 17)),
        ]),
        const SizedBox(height: 24),
        TextField(key: const ValueKey('session-search'), controller: _search, focusNode: widget.focusNode,
          onChanged: (_) => setState(() {}), style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(hintText: 'Search sessions', prefixIcon: const Icon(Icons.search, size: 17),
            filled: true, fillColor: const Color(0xfff9f9f9),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: opencodeBorder)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: opencodeFaint)))),
        const SizedBox(height: 16),
        Expanded(child: entries.isEmpty
          ? Center(child: Text(query.isEmpty ? 'Open a project to start a session.' : 'No sessions found.',
              style: const TextStyle(fontSize: 13, color: opencodeFaint)))
          : ListView.builder(itemCount: entries.length, itemBuilder: (context, index) {
              final (project, task) = entries[index];
              final status = _taskStatus(widget.session, task);
              return _taskMenu(context, widget.session, task, widget.onArchive,
                child: SidebarHover(builder: (context, active) => ListTile(
                key: ValueKey('home:${task.id}'), contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: ProjectAvatar(project: project, generated: widget.session.projectAvatarStyle == 'generated'),
                title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: _taskTitleStyle(status)),
                subtitle: Text(project.name, style: const TextStyle(fontSize: 12, color: opencodeFaint)),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  _taskStatusIndicator(task, status),
                  if (active || pins.containsKey(task.id)) _taskPinButton(widget.session, task),
                ]),
                onTap: () => widget.onSelect(project, task))));
            })),
      ])),
    ));
  }
}

Widget _navigationButton(String title, IconData icon, VoidCallback onTap, {bool selected = false}) =>
  Material(color: selected ? opencodeLayer : Colors.transparent, borderRadius: BorderRadius.circular(6),
    child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(6),
      child: SizedBox(height: 30, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Row(children: [
        Icon(icon, size: 16, color: opencodeFaint), const SizedBox(width: 8),
        Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, height: 16 / 13, color: opencodeFaint))),
      ])))));

Widget _draftTab(DesktopSession session, SessionDraft draft, {required bool vertical,
  required bool home, required VoidCallback onTap}) {
  final project = session.projects.where((project) => project.checkoutKey == draft.checkoutKey).firstOrNull;
  final selected = !home && session.task == null && session.currentDraft == draft;
  return SidebarHover(builder: (context, active) => Material(
    color: selected ? opencodeLayer : Colors.transparent, borderRadius: BorderRadius.circular(6),
    child: InkWell(borderRadius: BorderRadius.circular(6), onTap: onTap,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Row(children: [
        if (project != null) ProjectAvatar(project: project, generated: session.projectAvatarStyle == 'generated')
        else const Icon(Icons.edit_outlined, size: 16, color: opencodeFaint),
        const SizedBox(width: 6),
        Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('New session', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, height: 16 / 13, color: opencodeInk)),
          if (vertical && project != null) Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, height: 16 / 12, color: opencodeMuted)),
        ])),
        SizedBox.square(dimension: 20, child: active ? IconButton(tooltip: 'Close tab', padding: EdgeInsets.zero,
          style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          onPressed: session.submitting ? null : () => unawaited(_navigationRun(session, () => session.closeDraft(draft))),
          icon: const Icon(Icons.close, size: 14, color: opencodeFaint)) : null),
      ]))),
  ));
}

Widget _taskMenu(BuildContext context, DesktopSession session, DesktopTask task,
    void Function(DesktopTask, bool) onArchive, {required Widget child}) => GestureDetector(
  onSecondaryTapDown: (details) async {
    final pinned = session.pinnedTaskIds.contains(task.id);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = overlay.globalToLocal(details.globalPosition);
    final action = await showMenu<String>(context: context,
      position: RelativeRect.fromSize(Rect.fromLTWH(position.dx, position.dy, 0, 0), overlay.size),
      items: [
        PopupMenuItem(value: 'pin', enabled: !task.archived && !task.archiving,
          child: Row(children: [
            SvgPicture.string(_pinSvg, width: 16, height: 16,
              colorFilter: const ColorFilter.mode(opencodeFaint, BlendMode.srcIn)),
            const SizedBox(width: 8),
            Text(pinned ? 'Unpin session' : 'Pin session'),
          ])),
        PopupMenuItem(value: 'archive', enabled: session.connected && !task.archiving,
          child: Text(task.archived ? 'Restore session' : 'Archive session')),
      ]);
    if (action == 'pin') await _navigationRun(session, () => session.pinTask(task, !pinned));
    if (action == 'archive') onArchive(task, !task.archived);
  },
  child: child,
);

Widget _taskPinButton(DesktopSession session, DesktopTask task) {
  final pinned = session.pinnedTaskIds.contains(task.id);
  return Semantics(toggled: pinned, child: SizedBox.square(dimension: 20, child: IconButton(
    key: ValueKey('pin:${task.id}'), tooltip: pinned ? 'Unpin session' : 'Pin session', padding: EdgeInsets.zero,
    style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    onPressed: task.archived || task.archiving ? null :
      () => unawaited(_navigationRun(session, () => session.pinTask(task, !pinned))),
    icon: SvgPicture.string(_pinSvg, width: 14, height: 14,
      colorFilter: ColorFilter.mode(pinned ? opencodeMuted : opencodeFaint, BlendMode.srcIn)),
  )));
}

const _pinSvg = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" fill="none">
<path d="M10 2L14 6M10.5 2.5L6.5 6.5L4.5 6.5L3 8L8 13L9.5 11.5V9.5L13.5 5.5M5.5 10.5L2 14" stroke="currentColor" stroke-linecap="square" stroke-linejoin="round"/>
</svg>''';

Future<void> _navigationRun(DesktopSession session, Future<void> Function() action) async {
  try { await action(); } catch (error) { session.showError(error); }
}

TextStyle _taskTitleStyle(String status, {bool selected = false}) => TextStyle(
  fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w400,
  color: selected || status != 'ready' ? opencodeInk : opencodeMuted,
);

Widget _taskStatusIndicator(DesktopTask task, String status, {bool compact = false}) {
  final (label, color, icon) = switch (status) {
    'working' => ('Working', const Color(0xff2872b5), null),
    'done' => ('Done', const Color(0xff43825c), Icons.check_circle_outline),
    'failed' => ('Failed', const Color(0xffc44848), Icons.error_outline),
    'interrupted' => ('Interrupted', const Color(0xffb67a2a), Icons.pause_circle_outline),
    _ => ('Idle', opencodeFaint, Icons.circle_outlined),
  };
  final age = _age(task.lastActivity);
  final text = status == 'ready' && age.isNotEmpty ? age : label;
  return Semantics(label: text == label || compact ? label : '$label, $text', excludeSemantics: true,
    child: Tooltip(message: label, child: Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox.square(dimension: 16, child: icon == null
        ? OpenCodeActivityIndicator(color: color)
        : Icon(icon, size: status == 'ready' ? 8 : 13, color: color)),
      if (!compact) ...[
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 11, height: 16 / 11, color: color)),
      ],
    ])),
  );
}

String _taskStatus(DesktopSession session, DesktopTask task) {
  if (task.running) return 'working';
  if (task.loadError != null) return 'failed';
  final terminal = _lastTerminal(task);
  final summary = task.projectionState['summary'] as Map?;
  final started = summary?['time']?['busy'] as int?;
  final ended = summary?['time']?['idle'] as int?;
  if (!task.loaded && started != null && (ended == null || started > ended)) {
    return 'interrupted';
  }
  final settled = terminal?['metadata']?['seq'] as int? ?? -1;
  if (task.loaded && (terminal == null || task.messages.values.any((message) => message['type'] == 'assistant' &&
      (message['metadata']?['seq'] as int? ?? -1) > settled))) {
    return 'interrupted';
  }
  if (task.lastActivity <= (session.viewedTasks[task.id] ?? -1)) return 'ready';
  final outcome = terminal?['outcome'] ?? summary?['outcome'];
  return outcome == 'failed' ? 'failed' : outcome == 'succeeded' ? 'done' : 'ready';
}

Map<String, dynamic>? _lastTerminal(DesktopTask task) {
  Map<String, dynamic>? last;
  for (final message in task.messages.values) {
    if (message['type'] != 'idle') continue;
    if (last == null || (message['metadata']['seq'] as int) > (last['metadata']['seq'] as int)) last = message;
  }
  return last;
}

int _finishedAt(DesktopTask task) {
  return _lastTerminal(task)?['time']?['created'] as int? ??
    task.projectionState['summary']?['time']?['idle'] as int? ?? 0;
}

String _age(int timestamp) {
  if (timestamp <= 0) return '';
  final minutes = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(timestamp)).inMinutes;
  return minutes < 1 ? 'now' : minutes < 60 ? '${minutes}m' : minutes < 1440 ? '${minutes ~/ 60}h' : '${minutes ~/ 1440}d';
}
