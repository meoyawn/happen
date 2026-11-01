import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'appearance.dart';
import 'session.dart';
import 'sidebar_hover.dart';
import 'window_chrome.dart';

// OpenCode: app/src/shell/titlebar/{titlebar,tab-nav,inbox}.tsx.
class OpenCodeSidebar extends StatelessWidget {
  const OpenCodeSidebar({super.key, required this.session, required this.home,
    required this.windowControls,
    required this.onHome, required this.onSearch, required this.onNew, required this.onSettings,
    required this.onSelect, required this.onArchive});
  final DesktopSession session;
  final bool home;
  final bool windowControls;
  final VoidCallback onHome, onSearch, onNew, onSettings;
  final void Function(Project, DesktopTask) onSelect;
  final void Function(DesktopTask, bool) onArchive;

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
              if (!home && session.task == null && session.project != null)
                _draftTab(session.project!),
              Expanded(child: OpenCodeTabStrip(session: session, vertical: true, home: home,
                onSelect: onSelect, onArchive: onArchive)),
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

  Widget _draftTab(Project project) => Container(
    key: const ValueKey('opencode-draft-tab'),
    height: 45, padding: const EdgeInsets.symmetric(horizontal: 6),
    decoration: BoxDecoration(color: opencodeLayer, borderRadius: BorderRadius.circular(6)),
    child: Row(children: [
      _projectAvatar(project), const SizedBox(width: 6),
      Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start,
        children: [const Text('New session', style: TextStyle(fontSize: 13, color: opencodeInk)),
          Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: opencodeMuted))])),
    ]),
  );

  Widget _inbox(BuildContext context) {
    final entries = [for (final project in session.projects) if (!project.removing)
      for (final task in project.tasks) (project, task)]
      ..sort((a, b) => b.$2.lastActivity.compareTo(a.$2.lastActivity));
    final needs = entries.where((entry) => !entry.$2.archived && _taskStatus(session, entry.$2) == 'failed').toList();
    final working = entries.where((entry) => !entry.$2.archived && entry.$2.running).toList()
      ..sort((a, b) => _runStarted(a.$2).compareTo(_runStarted(b.$2)));
    final finished = entries.where((entry) => !entry.$2.running && !needs.contains(entry) &&
      _finishedAt(entry.$2) >= (session.inboxSince ?? 0)).toList()
      ..sort((a, b) => _finishedAt(b.$2).compareTo(_finishedAt(a.$2)));
    final recent = finished.where((entry) => !entry.$2.archived).toList();
    final archived = finished.where((entry) => entry.$2.archived).toList();
    return LayoutBuilder(builder: (context, constraints) {
      final visibleWorking = working.where((entry) => session.inboxWorkingExpanded || !home && session.task == entry.$2).toList();
      final workingHeight = working.isEmpty ? 0.0 : math.min(36.0 + visibleWorking.length * 68, constraints.maxHeight * .45);
      return Column(children: [
        Expanded(child: ListView(padding: EdgeInsets.zero, children: [
          if (needs.isNotEmpty) ...[
            _inboxHeading('Needs attention', count: needs.length),
            for (final (project, task) in needs) _inboxRow(context, project, task),
          ],
          if (recent.isNotEmpty) ...[
            if (needs.isNotEmpty) _inboxHeading('Recent'),
            for (final (project, task) in recent) _inboxRow(context, project, task),
          ],
          if (archived.isNotEmpty) ...[
            _inboxHeading('Archived'),
            for (final (project, task) in archived) _inboxRow(context, project, task),
          ],
          if (needs.isEmpty && recent.isEmpty && working.isEmpty && archived.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 24, horizontal: 6),
              child: Text('No sessions in your inbox yet.', style: TextStyle(fontSize: 12, color: opencodeFaint))),
        ])),
        if (working.isNotEmpty) SizedBox(height: workingHeight, child: Column(children: [
          _inboxHeading('Working', count: working.length, expanded: session.inboxWorkingExpanded,
            onTap: () => unawaited(_navigationRun(session, () => session.chooseInboxWorkingExpanded(!session.inboxWorkingExpanded)))),
          Expanded(child: ListView(padding: EdgeInsets.zero, children: [
            for (final (project, task) in visibleWorking) _inboxRow(context, project, task),
          ])),
        ])),
      ]);
    });
  }

  Widget _inboxHeading(String label, {int? count, bool? expanded, VoidCallback? onTap}) =>
    InkWell(onTap: onTap, borderRadius: BorderRadius.circular(6), child: SizedBox(height: 36, child: Row(children: [
      if (expanded != null) Icon(expanded ? Icons.keyboard_arrow_down : Icons.chevron_right, size: 14, color: opencodeFaint),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(label, style: const TextStyle(fontSize: 12, color: opencodeFaint))),
      if (count != null) Text('$count', style: const TextStyle(fontSize: 11, color: opencodeFaint)),
    ])));

  Widget _inboxRow(BuildContext context, Project project, DesktopTask task) {
    final status = _taskStatus(session, task);
    final selected = !home && session.task == task;
    final color = switch (status) {
      'failed' => const Color(0xffc44848),
      'working' => const Color(0xff5477b8),
      'done' => const Color(0xff43825c),
      _ => opencodeFaint,
    };
    final statusLabel = switch (status) {
      'failed' => 'Failed', 'working' => 'Working', 'done' => 'Done', _ => _age(task.lastActivity),
    };
    return Padding(padding: const EdgeInsets.only(bottom: 4), child: _taskMenu(context, session, task, onArchive,
      child: Material(color: selected ? opencodeLayer : Colors.transparent, borderRadius: BorderRadius.circular(6),
        child: InkWell(key: ValueKey('inbox:${task.id}'), borderRadius: BorderRadius.circular(6),
          onTap: () => onSelect(project, task), child: Opacity(opacity: task.archived && !selected ? .5 : status == 'working' && !selected ? .7 : 1,
            child: Padding(padding: const EdgeInsets.all(6), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                _projectAvatar(project), const SizedBox(width: 6),
                Expanded(child: Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, height: 16 / 12, color: opencodeFaint))),
                const SizedBox(width: 6),
                Text(statusLabel, style: TextStyle(fontSize: 12, height: 16 / 12, color: color)),
              ]),
              const SizedBox(height: 2),
              Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, height: 16 / 13, color: status == 'done' || status == 'failed' ? opencodeInk : opencodeMuted)),
              if (project.branch case final branch?) ...[
                const SizedBox(height: 2),
                Tooltip(message: project.path, child: Row(children: [
                  const Icon(Icons.fork_right, size: 12, color: opencodeFaint), const SizedBox(width: 4),
                  Expanded(child: Text(branch, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, height: 16 / 12, color: opencodeFaint))),
                ])),
              ],
            ])),
          )),
      ),
    ));
  }
}

class OpenCodeTopBar extends StatelessWidget {
  const OpenCodeTopBar({super.key, required this.session, required this.home,
    required this.leadingInset,
    required this.onHome, required this.onSearch, required this.onNew, required this.onSettings,
    required this.onSelect, required this.onArchive});
  final DesktopSession session;
  final bool home;
  final double leadingInset;
  final VoidCallback onHome, onSearch, onNew, onSettings;
  final void Function(Project, DesktopTask) onSelect;
  final void Function(DesktopTask, bool) onArchive;

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
        onSelect: onSelect, onArchive: onArchive)),
      if (!home && session.task == null && session.project != null)
        Container(width: 156, height: 28, padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: opencodeLayer, borderRadius: BorderRadius.circular(6)),
          child: const Align(alignment: Alignment.centerLeft, child: Text('New session', style: TextStyle(fontSize: 13)))),
      IconButton(tooltip: 'New session', onPressed: onNew, visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.add, size: 17)),
      IconButton(tooltip: 'App settings', onPressed: onSettings, visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.settings_outlined, size: 16)),
      const SizedBox(width: 8),
    ])));
}

class OpenCodeTabStrip extends StatelessWidget {
  const OpenCodeTabStrip({super.key, required this.session, required this.vertical, required this.home,
    required this.onSelect, required this.onArchive});
  final DesktopSession session;
  final bool vertical, home;
  final void Function(Project, DesktopTask) onSelect;
  final void Function(DesktopTask, bool) onArchive;

  @override
  Widget build(BuildContext context) {
    final tabs = session.openTasks;
    return LayoutBuilder(builder: (context, constraints) => ReorderableListView.builder(
      key: ValueKey('opencode-tabs:${vertical ? 'side' : 'top'}'),
      scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
      buildDefaultDragHandles: false, padding: EdgeInsets.zero,
      itemExtent: vertical ? 49 : (constraints.maxWidth / math.max(1, tabs.length)).clamp(80.0, 220.0),
      itemCount: tabs.length,
      proxyDecorator: (child, _, animation) => Material(color: const Color(0xfff9f9f9), borderRadius: BorderRadius.circular(6), child: child),
      onReorderItem: (oldIndex, newIndex) {
        final ids = tabs.map((entry) => entry.$2.id).toList();
        ids.insert(newIndex, ids.removeAt(oldIndex));
        ids.addAll(session.openTaskIds.where((id) => !ids.contains(id)));
        unawaited(_navigationRun(session, () => session.reorderTabs(ids)));
      },
      itemBuilder: (context, index) {
        final (project, task) = tabs[index];
        final selected = !home && session.task == task;
        return ReorderableDragStartListener(key: ValueKey('opencode-tab:${task.id}'), index: index,
          child: Padding(padding: vertical ? const EdgeInsets.only(bottom: 4) : const EdgeInsets.symmetric(horizontal: 3, vertical: 6),
            child: _taskMenu(context, session, task, onArchive, child: SidebarHover(builder: (context, active) => Material(
              color: selected ? opencodeLayer : Colors.transparent, borderRadius: BorderRadius.circular(6),
              child: InkWell(borderRadius: BorderRadius.circular(6), onTap: () => onSelect(project, task),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: Row(children: [
                  _projectAvatar(project), const SizedBox(width: 6),
                  Expanded(child: Tooltip(message: '${task.title}\n${project.path}', child: Column(
                    mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13, height: 16 / 13, color: opencodeInk)),
                      if (vertical) Text(project.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, height: 16 / 12, color: opencodeMuted)),
                    ]))),
                  SizedBox(width: 20, height: 20, child: active
                    ? IconButton(tooltip: 'Close tab', padding: EdgeInsets.zero,
                        style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        onPressed: () => unawaited(_navigationRun(session, () => session.closeTab(task))),
                        icon: const Icon(Icons.close, size: 14, color: opencodeFaint))
                    : Center(child: task.running
                        ? const SizedBox.square(dimension: 10, child: CircularProgressIndicator(strokeWidth: 1.3, color: opencodeFaint))
                        : _taskStatus(session, task) == 'done' || _taskStatus(session, task) == 'failed'
                          ? Container(width: 7, height: 7, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xff5876db)))
                          : null)),
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
    required this.onSelect, required this.onNew, required this.onAddProject});
  final DesktopSession session;
  final FocusNode focusNode;
  final void Function(Project, DesktopTask) onSelect;
  final ValueChanged<Project> onNew;
  final VoidCallback onAddProject;

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
    final entries = [for (final project in widget.session.projects) if (!project.removing)
      for (final task in project.tasks)
        if (!task.archived && '${task.title} ${project.name} ${project.path}'.toLowerCase().contains(query)) (project, task)]
      ..sort((a, b) => b.$2.lastActivity.compareTo(a.$2.lastActivity));
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
              return ListTile(key: ValueKey('home:${task.id}'), contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                leading: _projectAvatar(project),
                title: Text(task.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: opencodeInk)),
                subtitle: Text(project.name, style: const TextStyle(fontSize: 12, color: opencodeFaint)),
                trailing: Text(_age(task.lastActivity), style: const TextStyle(fontSize: 12, color: opencodeFaint)),
                onTap: () => widget.onSelect(project, task));
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

Widget _projectAvatar(Project project) {
  const colors = [Color(0xffd64f60), Color(0xffa477c4), Color(0xffc18850), Color(0xff5488af), Color(0xff6c9d78)];
  final hash = project.name.codeUnits.fold(0, (value, char) => value * 31 + char);
  return Container(width: 16, height: 16, alignment: Alignment.center,
    decoration: BoxDecoration(color: colors[hash.abs() % colors.length], borderRadius: BorderRadius.circular(4)),
    child: Text(project.name.isEmpty ? '?' : project.name.characters.first.toUpperCase(),
      style: const TextStyle(fontFamily: 'Inter', fontSize: 11, height: 1, fontWeight: FontWeight.w600, color: Colors.white)));
}

Widget _taskMenu(BuildContext context, DesktopSession session, DesktopTask task,
    void Function(DesktopTask, bool) onArchive, {required Widget child}) => GestureDetector(
  onSecondaryTapDown: (details) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = overlay.globalToLocal(details.globalPosition);
    final action = await showMenu<String>(context: context,
      position: RelativeRect.fromSize(Rect.fromLTWH(position.dx, position.dy, 0, 0), overlay.size),
      items: [PopupMenuItem(value: 'archive', enabled: session.connected && !task.archiving,
        child: Text(task.archived ? 'Restore session' : 'Archive session'))]);
    if (action == 'archive') onArchive(task, !task.archived);
  },
  child: child,
);

Future<void> _navigationRun(DesktopSession session, Future<void> Function() action) async {
  try { await action(); } catch (error) { session.showError(error); }
}

String _taskStatus(DesktopSession session, DesktopTask task) {
  if (task.running) return 'working';
  if (task.loadError != null) return 'failed';
  if (task.lastActivity <= (session.viewedTasks[task.id] ?? -1)) return 'ready';
  final outcome = _lastTerminal(task);
  return outcome?['outcome'] == 'failed' ? 'failed' : outcome?['outcome'] == 'succeeded' ? 'done' : 'ready';
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
  return _lastTerminal(task)?['time']?['created'] as int? ?? 0;
}

int _runStarted(DesktopTask task) {
  var started = 0;
  for (final message in task.messages.values) {
    if (message['type'] != 'assistant') continue;
    final time = message['time']?['created'] as int? ?? 0;
    if (time > started) started = time;
  }
  return started == 0 ? task.lastActivity : started;
}

String _age(int timestamp) {
  if (timestamp <= 0) return '';
  final minutes = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(timestamp)).inMinutes;
  return minutes < 1 ? 'now' : minutes < 60 ? '${minutes}m' : minutes < 1440 ? '${minutes ~/ 60}h' : '${minutes ~/ 1440}d';
}
