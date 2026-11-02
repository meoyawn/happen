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
    required this.onOpen});
  final DesktopSession session;
  final List<CommandMenuAction> actions;
  final void Function(Project, DesktopTask) onOpen;

  @override
  State<CommandMenu> createState() => _CommandMenuState();
}

class _CommandMenuState extends State<CommandMenu> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  late final _searchFocus = FocusNode(onKeyEvent: _searchKey);
  String? _activeId;

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

  List<_Entry> get _entries {
    final words = _search.text.toLowerCase().trim().split(RegExp(r'\s+'));
    bool matches(String value) => words.every(value.toLowerCase().contains);
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
    return index < 0 ? 0 : index;
  }

  void _move(int offset) {
    final entries = _entries;
    if (entries.isEmpty) return;
    final index = (_activeIndex(entries) + offset) % entries.length;
    setState(() => _activeId = entries[index].id);
    if (!_scroll.hasClients) return;
    var top = 0.0;
    for (var i = 0; i <= index; i++) {
      if (i == 0 || entries[i - 1].group != entries[i].group) top += 28;
      if (i < index) top += 40;
    }
    final position = _scroll.position;
    final target = top < position.pixels ? top
      : top + 40 > position.pixels + position.viewportDimension
        ? top + 40 - position.viewportDimension : position.pixels;
    _scroll.jumpTo(target.clamp(0.0, position.maxScrollExtent));
  }

  void _activate() {
    final entries = _entries;
    if (entries.isEmpty) return;
    final entry = entries[_activeIndex(entries)];
    entry.select();
  }

  KeyEventResult _searchKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isMetaPressed || keyboard.isControlPressed ||
        keyboard.isAltPressed || keyboard.isShiftPressed) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowDown: _move(1);
      case LogicalKeyboardKey.arrowUp: _move(-1);
      case LogicalKeyboardKey.enter:
        if (event is KeyDownEvent) _activate();
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
        insetPadding: EdgeInsets.fromLTRB(12,
          ((MediaQuery.sizeOf(context).height - 480) / 2).clamp(48.0, double.infinity), 12, 24),
        backgroundColor: Colors.white, surfaceTintColor: Colors.transparent,
        elevation: 16, shadowColor: const Color(0x33000000),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: opencodeBorder, width: .5)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 480, child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: ListenableBuilder(
            listenable: Listenable.merge([widget.session, _search]),
            builder: (context, _) {
              final entries = _entries;
              final active = entries.isEmpty ? null : entries[_activeIndex(entries)];
              return Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(padding: const EdgeInsets.all(6), child: Row(children: [
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.search, size: 16, color: opencodeMuted)),
                  Expanded(child: TextField(
                    key: const ValueKey('command-menu-search'),
                    controller: _search, focusNode: _searchFocus, autofocus: true,
                    style: const TextStyle(fontSize: 13, height: 20 / 13, color: opencodeInk),
                    decoration: InputDecoration(
                      hintText: 'Search sessions and commands…',
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
                Flexible(child: entries.isEmpty
                  ? const Padding(padding: EdgeInsets.all(32), child: Text('No results',
                      style: const TextStyle(fontSize: 13, color: opencodeMuted)))
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
                    const Text('Open', style: TextStyle(fontSize: 11, color: opencodeFaint)),
                  ])),
              ]);
            },
          ),
        )),
      ),
    );
  }

  Widget _row(_Entry entry, bool active) {
    final task = entry.task;
    return MouseRegion(
      onEnter: (_) => setState(() => _activeId = entry.id),
      child: Semantics(selected: active, button: true, child: Material(
        color: active ? opencodeLayer : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: ValueKey('command-menu:${entry.id}'),
          borderRadius: BorderRadius.circular(6),
          onTap: task?.archiving == true ? null : entry.select,
          child: SizedBox(height: 40, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              if (entry.project case final project?)
                ProjectAvatar(project: project, generated: widget.session.projectAvatarStyle == 'generated')
              else
                Icon(entry.icon, size: 16, color: opencodeMuted),
              const SizedBox(width: 8),
              Flexible(child: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, height: 16 / 13,
                  color: opencodeInk))),
              if (entry.description.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(child: Text(entry.description, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: opencodeFaint))),
              ],
              const Spacer(),
              if (task == widget.session.task && task != null)
                const Padding(padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.check, size: 14, color: opencodeFaint)),
              if (entry.shortcut case final shortcut?) _KeyHint(shortcut),
            ]),
          )),
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
