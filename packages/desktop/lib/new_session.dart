import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'appearance.dart';
import 'session.dart';
import 'project_avatar.dart';

// OpenCode's new-session location tray, with an anchored project menu.
class NewSessionScreen extends StatelessWidget {
  const NewSessionScreen({super.key, required this.session, required this.composer,
    required this.picking, required this.onSelect, required this.onAddProject,
    required this.onRemoveProject, required this.onReturnFocus});
  final DesktopSession session;
  final Widget composer;
  final bool picking;
  final ValueChanged<Project> onSelect, onRemoveProject;
  final VoidCallback onAddProject, onReturnFocus;

  @override
  Widget build(BuildContext context) {
    final project = session.project;
    final hasProjects = session.projects.any((project) => !project.removing);
    final buttonStyle = TextButton.styleFrom(foregroundColor: opencodeMuted,
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 13,
        height: 20 / 13, letterSpacing: -.04, fontWeight: FontWeight.w400),
      padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: const Size(0, 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)));
    return LayoutBuilder(builder: (context, bounds) => SingleChildScrollView(
      child: Padding(padding: EdgeInsets.fromLTRB(12, (bounds.maxHeight * .22).clamp(24.0, 200.0), 12, 32),
        child: Align(alignment: Alignment.topCenter,
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: opencodeSessionWidth),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('Happen',
                style: TextStyle(fontSize: 40, height: 1.2, fontWeight: FontWeight.w700,
                  letterSpacing: -2, color: Color(0xffc8c8c8)))),
              const SizedBox(height: 24),
              composer,
              Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
                child: LayoutBuilder(builder: (context, tray) => Row(children: [
                  if (hasProjects) ...[
                    ConstrainedBox(constraints: BoxConstraints(maxWidth: tray.maxWidth * .4),
                      child: MenuAnchor(
                        onClose: onReturnFocus,
                        style: MenuStyle(padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                          backgroundColor: const WidgetStatePropertyAll(Colors.white),
                          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
                          elevation: const WidgetStatePropertyAll(8),
                          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(8),
                            side: const BorderSide(color: opencodeBorder)))),
                        menuChildren: [Builder(builder: (context) => _ProjectPicker(
                          projects: session.projects.where((project) => !project.removing).toList(), selected: project,
                          onSelect: (project) { MenuController.maybeOf(context)?.close(); onSelect(project); },
                          onAdd: () { MenuController.maybeOf(context)?.close(); onAddProject(); }))],
                        builder: (context, controller, _) => Tooltip(message: 'Select project', child: TextButton(
                          onPressed: picking || session.submitting ? null : () => controller.isOpen ? controller.close() : controller.open(),
                          style: buttonStyle,
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            if (project != null) ProjectAvatar(project: project)
                            else const Icon(Icons.folder_open_outlined, size: 16),
                            const SizedBox(width: 6),
                            Flexible(child: Text(project?.name ?? 'Select project', maxLines: 1, overflow: TextOverflow.ellipsis)),
                            const SizedBox(width: 6), const Icon(Icons.keyboard_arrow_down_rounded, size: 14),
                          ]))))),
                    if (project?.branch != null && tray.maxWidth >= 520) ...[
                      const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('/', style: TextStyle(color: opencodeFaint))),
                      ConstrainedBox(constraints: const BoxConstraints(maxWidth: 140), child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.fork_right, size: 14, color: opencodeFaint), const SizedBox(width: 4),
                        Flexible(child: Text(project!.branch!, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: opencodeFaint))),
                      ])),
                    ],
                    if (project != null && tray.maxWidth >= 640)
                      Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Tooltip(message: project.path, child: Text(project.path,
                          maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12, color: opencodeFaint)))))
                    else const Spacer(),
                  ],
                  if (!hasProjects) TextButton.icon(onPressed: picking || session.submitting ? null : onAddProject, style: buttonStyle,
                    icon: picking
                      ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.5))
                      : const Icon(Icons.create_new_folder_outlined, size: 16),
                    label: Text(picking ? 'Opening project…' : 'Add project')),
                ]))),
              if (project?.removing == true)
                const Padding(padding: EdgeInsets.all(12), child: Text('Removing project…', style: TextStyle(fontSize: 13, color: opencodeFaint)))
              else if (project?.available == false)
                Padding(padding: const EdgeInsets.all(12), child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                  const Text('Project folder is unavailable. Choose another project.', style: TextStyle(fontSize: 13, color: opencodeFaint)),
                  TextButton(onPressed: () => onRemoveProject(project!), child: const Text('Remove project')),
                ])),
              if (session.error case final error?)
                Padding(padding: const EdgeInsets.all(12), child: SelectableText(error,
                  style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.error))),
            ]),
          ),
        ),
      ),
    ));
  }
}

class _ProjectPicker extends StatefulWidget {
  const _ProjectPicker({required this.projects, required this.selected, required this.onSelect, required this.onAdd});
  final List<Project> projects;
  final Project? selected;
  final ValueChanged<Project> onSelect;
  final VoidCallback onAdd;

  @override
  State<_ProjectPicker> createState() => _ProjectPickerState();
}

class _ProjectPickerState extends State<_ProjectPicker> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  int _active = 0;

  List<Project> get _projects {
    final query = _search.text.trim().toLowerCase();
    return widget.projects.where((project) => '${project.name} ${project.path}'.toLowerCase().contains(query)).toList()
      ..sort((a, b) => b.tasks.fold(0, (latest, task) => task.lastActivity > latest ? task.lastActivity : latest)
        .compareTo(a.tasks.fold(0, (latest, task) => task.lastActivity > latest ? task.lastActivity : latest)));
  }

  @override
  void initState() {
    super.initState();
    _active = _projects.indexWhere((project) => project == widget.selected).clamp(0, widget.projects.length);
  }

  @override
  void dispose() { _search.dispose(); _scroll.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final projects = _projects;
    void select() {
      if (_active == projects.length) { widget.onAdd(); }
      else if (projects[_active].available) { widget.onSelect(projects[_active]); }
    }
    return SizedBox(width: 360, child: Focus(onKeyEvent: (_, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.enter) { select(); return KeyEventResult.handled; }
      if (key != LogicalKeyboardKey.arrowDown && key != LogicalKeyboardKey.arrowUp) return KeyEventResult.ignored;
      setState(() {
        do {
          _active = (_active + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) % (projects.length + 1);
        } while (_active < projects.length && !projects[_active].available);
      });
      if (_scroll.hasClients) _scroll.jumpTo((_active * 48.0 - 144).clamp(0.0, _scroll.position.maxScrollExtent));
      return KeyEventResult.handled;
    }, child: Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: TextField(
        key: const ValueKey('project-search'), controller: _search, autofocus: true,
        onChanged: (_) => setState(() => _active = 0),
        style: const TextStyle(fontSize: 13, height: 20 / 13),
        decoration: const InputDecoration(hintText: 'Search projects', border: InputBorder.none,
          enabledBorder: InputBorder.none, focusedBorder: InputBorder.none,
          prefixIcon: Icon(Icons.search, size: 16), prefixIconConstraints: BoxConstraints(minWidth: 28)))),
      const Divider(height: 1),
      Flexible(child: projects.isEmpty
        ? const Padding(padding: EdgeInsets.all(24), child: Text('No projects found.', style: TextStyle(fontSize: 13, color: opencodeFaint)))
        // MenuAnchor measures intrinsic dimensions, which viewports cannot supply.
        // Bound the list by its row heights and padding instead of shrink-wrapping.
        : SizedBox(height: (projects.length * 48.0 + 8).clamp(0.0, 288.0),
          child: ListView(controller: _scroll, padding: const EdgeInsets.all(4), itemExtent: 48, children: [
              for (var index = 0; index < projects.length; index++)
                _row(projects[index].name, projects[index].available ? projects[index].path : 'Folder unavailable · ${projects[index].path}',
                  ProjectAvatar(project: projects[index], size: 20), active: _active == index,
                  selected: projects[index] == widget.selected, enabled: projects[index].available,
                  onTap: () => widget.onSelect(projects[index])),
            ]))),
      const Divider(height: 1),
      Padding(padding: const EdgeInsets.all(4), child: _row('Add project', null,
        const Icon(Icons.create_new_folder_outlined, size: 18, color: opencodeMuted),
        active: _active == projects.length, onTap: widget.onAdd)),
    ])));
  }

  Widget _row(String title, String? subtitle, Widget icon, {required bool active,
    bool selected = false, bool enabled = true, required VoidCallback onTap}) => Material(
    color: active ? opencodeLayer : Colors.transparent, borderRadius: BorderRadius.circular(4),
    child: InkWell(onTap: enabled ? onTap : null, borderRadius: BorderRadius.circular(4),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), child: Opacity(
        opacity: enabled ? 1 : .45, child: Row(children: [
          icon, const SizedBox(width: 10), Expanded(child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, height: 16 / 13, color: opencodeInk)),
              if (subtitle != null) Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, height: 16 / 11, color: opencodeFaint)),
            ])),
          if (selected) const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.check_rounded, size: 14, color: opencodeMuted)),
        ])))));
}
