import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'appearance.dart';
import 'project_avatar.dart';
import 'session.dart';

typedef CommandMenuAction = ({
  String title, String keywords, IconData icon, String? shortcut, VoidCallback run,
});

typedef _Entry = ({
  String id, String group, String title, String description, IconData? icon,
  String? shortcut, Project? project, DesktopTask? task, VoidCallback select,
});

class CommandMenu extends StatefulWidget {
  const CommandMenu({super.key, required this.session, required this.actions,
    required this.onOpen, required this.onNewThread, required this.onAddProject,
    this.pickProject = false});
  final DesktopSession session;
  final List<CommandMenuAction> actions;
  final void Function(Project, DesktopTask) onOpen;
  final ValueChanged<Project> onNewThread;
  final VoidCallback onAddProject;
  final bool pickProject;

  @override
  State<CommandMenu> createState() => _CommandMenuState();
}

class _CommandMenuState extends State<CommandMenu> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  late final _searchFocus = FocusNode(onKeyEvent: _searchKey);
  String? _activeId;
  bool _projectsOpen = false;

  @override
  void initState() {
    super.initState();
    _projectsOpen = widget.pickProject;
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _close(VoidCallback action) {
    Navigator.of(context).pop();
    action();
  }

  void _showProjects(bool opened) {
    setState(() {
      _projectsOpen = opened;
      _activeId = null;
      _search.clear();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _searchFocus.requestFocus();
  }

  List<_Entry> get _entries {
    final words = _search.text.toLowerCase().trim().split(RegExp(r'\s+'));
    bool matches(String value) => words.every(value.toLowerCase().contains);
    if (_projectsOpen) {
      final session = widget.session;
      final projects = session.projects.where((project) => !project.removing &&
        matches('${project.name} ${project.path}')).toList();
      final order = {for (final (index, project) in session.projects.indexed) project: index};
      int latest(Project project) => project.tasks.fold(0,
        (value, task) => task.lastActivity > value ? task.lastActivity : value);
      projects.sort((a, b) {
        final preferred = (b == session.project ? 1 : 0).compareTo(a == session.project ? 1 : 0);
        if (preferred != 0) return preferred;
        final pinned = (session.pinnedProjectKeys.contains(b.checkoutKey) ? 1 : 0)
          .compareTo(session.pinnedProjectKeys.contains(a.checkoutKey) ? 1 : 0);
        if (pinned != 0) return pinned;
        final activity = latest(b).compareTo(latest(a));
        return activity != 0 ? activity : order[a]!.compareTo(order[b]!);
      });
      return [
        for (final project in projects)
          (id: 'project:${project.checkoutKey}', group: 'Projects', title: project.name,
            description: project.available
              ? '${session.client.sharedFilesystem ? 'Local' : 'Remote'} · ${project.path}'
              : 'Folder unavailable · ${project.path}',
            icon: null, shortcut: null, project: project, task: null,
            select: () {
              if (project.available && !project.removing) _close(() => widget.onNewThread(project));
            }),
        (id: 'add-project', group: 'Actions', title: 'Add project',
          description: '', icon: Icons.create_new_folder_outlined, shortcut: null,
          project: null, task: null, select: () => _close(widget.onAddProject)),
      ];
    }
    final tasks = [
      for (final project in widget.session.projects)
        if (!project.removing)
          for (final task in project.tasks)
            if (!task.archived && matches('${task.title} ${project.name} ${project.path}'))
              (project, task),
    ]..sort((a, b) {
      final activity = b.$2.lastActivity.compareTo(a.$2.lastActivity);
      return activity != 0 ? activity : a.$2.id.compareTo(b.$2.id);
    });
    return [
      if (matches('New thread in… new chat task session project pick choose select'))
        (id: 'new-thread', group: 'Commands', title: 'New thread in…',
          description: '', icon: Icons.edit_square,
          shortcut: defaultTargetPlatform == TargetPlatform.macOS ? '⌘ N' : 'Ctrl N',
          project: null, task: null, select: () => _showProjects(true)),
      for (final action in widget.actions)
        if (matches('${action.title} ${action.keywords}'))
          (id: 'command:${action.title}', group: 'Commands', title: action.title,
            description: '', icon: action.icon, shortcut: action.shortcut,
            project: null, task: null, select: () => _close(action.run)),
      for (final (project, task) in tasks)
        (id: task.id, group: 'Sessions', title: task.title,
          description: project.name, icon: null, shortcut: null,
          project: project, task: task, select: () => _open(project, task)),
    ];
  }

  void _open(Project project, DesktopTask task) {
    if (task.archiving || task.archived) return;
    _close(() => widget.onOpen(project, task));
  }

  int _activeIndex(List<_Entry> entries) {
    final index = entries.indexWhere((entry) => entry.id == _activeId);
    return index >= 0 && _enabled(entries[index]) ? index : entries.indexWhere(_enabled);
  }

  bool _enabled(_Entry entry) => entry.task?.archiving != true &&
    (entry.task != null || entry.project == null || entry.project!.available && !entry.project!.removing);

  void _move(int offset) {
    final entries = _entries;
    if (entries.isEmpty) return;
    var index = _activeIndex(entries);
    if (index < 0) return;
    do {
      index = (index + offset) % entries.length;
    } while (!_enabled(entries[index]));
    setState(() => _activeId = entries[index].id);
    if (!_scroll.hasClients) return;
    var top = 0.0;
    for (var i = 0; i <= index; i++) {
      if (i == 0 || entries[i - 1].group != entries[i].group) top += 28;
      if (i < index) top += _rowHeight(entries[i]);
    }
    final position = _scroll.position;
    final bottom = top + _rowHeight(entries[index]);
    final target = top < position.pixels ? top
      : bottom > position.pixels + position.viewportDimension
        ? bottom - position.viewportDimension : position.pixels;
    _scroll.jumpTo(target.clamp(0.0, position.maxScrollExtent));
  }

  void _activate() {
    if (!_search.value.composing.isCollapsed) return;
    final entries = _entries;
    if (entries.isEmpty) return;
    final index = _activeIndex(entries);
    if (index < 0) return;
    final entry = entries[index];
    entry.select();
  }

  KeyEventResult _searchKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed || keyboard.isControlPressed ||
        keyboard.isAltPressed || keyboard.isShiftPressed) { return KeyEventResult.ignored; }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown: _move(1);
      case LogicalKeyboardKey.arrowUp: _move(-1);
      case LogicalKeyboardKey.enter:
        if (event is KeyDownEvent) _activate();
      case LogicalKeyboardKey.backspace:
        if (!_projectsOpen || _search.text.isNotEmpty) return KeyEventResult.ignored;
        if (event is KeyDownEvent) _showProjects(false);
      default: return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.enter): _activate,
        const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).pop(),
        SingleActivator(LogicalKeyboardKey.keyK, meta: mac, control: !mac): () => Navigator.of(context).pop(),
      },
      child: Dialog(
        key: const ValueKey('command-menu'),
        alignment: Alignment.topCenter,
        insetPadding: EdgeInsets.fromLTRB(16,
          (MediaQuery.sizeOf(context).height * .1).clamp(48.0, double.infinity), 16, 24),
        backgroundColor: Colors.white, surfaceTintColor: Colors.transparent,
        elevation: 16, shadowColor: const Color(0x33000000),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: opencodeBorder, width: .5)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 576, child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: ListenableBuilder(
            listenable: Listenable.merge([widget.session, _search]),
            builder: (context, _) {
              final entries = _entries;
              final activeIndex = _activeIndex(entries);
              final active = activeIndex < 0 ? null : entries[activeIndex];
              return Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(padding: const EdgeInsets.all(6), child: Row(children: [
                  if (_projectsOpen)
                    IconButton(tooltip: 'Back', onPressed: () => _showProjects(false),
                      icon: const Icon(Icons.arrow_back, size: 16, color: opencodeMuted),
                      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                      padding: EdgeInsets.zero)
                  else
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.search, size: 16, color: opencodeMuted)),
                  Expanded(child: TextField(
                    key: const ValueKey('command-menu-search'),
                    controller: _search, focusNode: _searchFocus, autofocus: true,
                    style: const TextStyle(fontSize: 13, height: 20 / 13, color: opencodeInk),
                    decoration: InputDecoration(
                      hintText: _projectsOpen ? 'Search projects…' : 'Search sessions and commands…',
                      hintStyle: const TextStyle(color: opencodeFaint),
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onChanged: (_) {
                      setState(() => _activeId = null);
                      if (_scroll.hasClients) _scroll.jumpTo(0);
                    },
                  )),
                  const _KeyHint('esc'),
                  const SizedBox(width: 6),
                ])),
                const Divider(height: 1, thickness: .5, color: opencodeBorder),
                if (_projectsOpen && !entries.any((entry) => entry.project != null))
                  const Padding(padding: EdgeInsets.all(24), child: Text('No projects found.',
                    style: TextStyle(fontSize: 13, color: opencodeMuted))),
                Flexible(child: entries.isEmpty
                  ? const Padding(padding: EdgeInsets.all(32), child: Text('No results',
                      style: TextStyle(fontSize: 13, color: opencodeMuted)))
                  : ListView.builder(
                      controller: _scroll, shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return Column(mainAxisSize: MainAxisSize.min, children: [
                          if (index == 0 || entries[index - 1].group != entry.group)
                            SizedBox(height: 28, child: Align(alignment: Alignment.centerLeft,
                              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8),
                                child: Text(entry.group, style: const TextStyle(fontSize: 12, color: opencodeMuted))))),
                          _row(entry, active?.id == entry.id),
                        ]);
                      },
                    )),
                const Divider(height: 1, thickness: .5, color: opencodeBorder),
                Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  child: Row(children: [
                    const _KeyHint('↑ ↓'),
                    const SizedBox(width: 6),
                    const Text('Navigate', style: TextStyle(fontSize: 11, color: opencodeFaint)),
                    const SizedBox(width: 14),
                    const _KeyHint('↵'),
                    const SizedBox(width: 6),
                    Text(_projectsOpen ? 'Select' : 'Open', style: const TextStyle(fontSize: 11, color: opencodeFaint)),
                    if (_projectsOpen) ...[
                      const SizedBox(width: 14),
                      const _KeyHint('⌫'),
                      const SizedBox(width: 6),
                      const Text('Back', style: TextStyle(fontSize: 11, color: opencodeFaint)),
                    ],
                    const Spacer(),
                    const _KeyHint('esc'),
                    const SizedBox(width: 6),
                    const Text('Close', style: TextStyle(fontSize: 11, color: opencodeFaint)),
                  ])),
              ]);
            },
          ),
        )),
      ),
    );
  }

  double _rowHeight(_Entry entry) => _projectsOpen && entry.project != null ? 48 : 40;

  Widget _row(_Entry entry, bool active) {
    final task = entry.task;
    final enabled = _enabled(entry);
    final projectRow = _projectsOpen && entry.project != null;
    return MouseRegion(
      onEnter: enabled ? (_) => setState(() => _activeId = entry.id) : null,
      child: Semantics(selected: active, enabled: enabled, button: true, child: Material(
        color: active ? opencodeLayer : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          mouseCursor: WidgetStateMouseCursor.clickable,
          key: ValueKey('command-menu:${entry.id}'),
          borderRadius: BorderRadius.circular(6),
          onTap: enabled ? entry.select : null,
          child: Opacity(opacity: enabled ? 1 : .45, child: SizedBox(height: _rowHeight(entry), child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              if (entry.project case final project?)
                ProjectAvatar(project: project, generated: widget.session.projectAvatarStyle == 'generated')
              else
                Icon(entry.icon, size: 16, color: opencodeMuted),
              const SizedBox(width: 8),
              if (projectRow)
                Expanded(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, height: 18 / 13, color: opencodeInk)),
                  Text(entry.description, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, height: 16 / 12, color: opencodeFaint)),
                ]))
              else ...[
                Flexible(child: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, height: 16 / 13, color: opencodeInk))),
                if (entry.description.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(child: Text(entry.description, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: opencodeFaint))),
                ],
                const Spacer(),
              ],
              if (task == widget.session.task && task != null)
                const Padding(padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.check, size: 14, color: opencodeFaint)),
              if (entry.shortcut case final shortcut?) _KeyHint(shortcut),
              if (entry.id == 'new-thread')
                const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.chevron_right, size: 14, color: opencodeFaint)),
            ]),
          ))),
        ),
      )),
    );
  }
}

class _KeyHint extends StatelessWidget {
  const _KeyHint(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
    decoration: BoxDecoration(border: Border.all(color: opencodeBorder, width: .5),
      borderRadius: BorderRadius.circular(4)),
    child: Text(label, style: const TextStyle(fontSize: 10, height: 1, color: opencodeFaint)),
  );
}
