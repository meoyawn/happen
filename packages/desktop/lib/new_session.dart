import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'appearance.dart';
import 'checkout_pull.dart';
import 'session.dart';
import 'project_avatar.dart';

// T3 Code's draft hero, project selector, and checkout toolbar.
class NewSessionScreen extends StatelessWidget {
  const NewSessionScreen({super.key, required this.session, required this.composer,
    required this.picking, required this.onSelect, required this.onAddProject,
    required this.onRemoveProject, required this.onReturnFocus, this.onOpenFolder, this.projectMenuController, this.machinePicker, this.sources});
  final Widget? machinePicker;
  final DesktopSession session;
  final List<DesktopSession>? sources;
  final Widget composer;
  final bool picking;
  final ValueChanged<Project> onSelect, onRemoveProject;
  final VoidCallback onAddProject, onReturnFocus;
  final VoidCallback? onOpenFolder;
  final MenuController? projectMenuController;

  @override
  Widget build(BuildContext context) {
    final project = session.project;
    final projects = desktopProjects(sources ?? [session], preferred: session);
    final hasProjects = projects.isNotEmpty;
    return LayoutBuilder(builder: (context, bounds) {
      final narrow = bounds.maxWidth < 600;
      final heading = TextStyle(fontSize: narrow ? 24 : 30, height: 1.25,
        fontWeight: FontWeight.w400, letterSpacing: -.9, color: desktopForeground);
      final projectSelector = MenuAnchor(
        controller: projectMenuController,
        onClose: onReturnFocus,
        style: MenuStyle(padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          backgroundColor: const WidgetStatePropertyAll(Colors.white),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(8),
          shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: desktopBorder)))),
        menuChildren: [Builder(builder: (context) => _ProjectPicker(
          projects: projects, selected: project == null ? null : projectIdentity(session, project),
          generated: session.projectAvatarStyle == 'generated',
          onSelect: (project) { MenuController.maybeOf(context)?.close(); onSelect(project); },
          onRemove: (project) { MenuController.maybeOf(context)?.close(); onRemoveProject(project); },
          onAdd: () { MenuController.maybeOf(context)?.close(); onAddProject(); }))],
        builder: (context, controller, _) => Tooltip(message: 'Select project', child: TextButton(
          onPressed: picking || session.submitting ? null : hasProjects
            ? () => controller.isOpen ? controller.close() : controller.open() : onAddProject,
          style: TextButton.styleFrom(foregroundColor: desktopForeground, padding: const EdgeInsets.symmetric(horizontal: 2),
            minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))),
          child: Text(project == null ? picking ? 'Opening project…' : hasProjects ? 'Choose a project' : 'Add a project'
            : '${project.name}${narrow ? '' : '?'}', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: heading.copyWith(fontWeight: FontWeight.w500, fontSize: narrow ? 20 : 30)))));
      return ColoredBox(color: const Color(0xfffdfdfd), child: Stack(children: [
        SingleChildScrollView(child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: ConstrainedBox(constraints: BoxConstraints(minHeight: (bounds.maxHeight - 80).clamp(0.0, double.infinity)),
            child: Align(alignment: const Alignment(0, -.12), child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: desktopNewThreadComposerWidth),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (narrow) Column(children: [
                  Text('What should we build?', textAlign: TextAlign.center, style: heading),
                  const SizedBox(height: 8),
                  projectSelector,
                ])
                else Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, spacing: 7, runSpacing: 6, children: [
                    Text(project == null ? 'What should we build?' : 'What should we build in', style: heading),
                    ConstrainedBox(constraints: BoxConstraints(maxWidth: (bounds.maxWidth - 48).clamp(0.0, desktopNewThreadComposerWidth)),
                      child: projectSelector),
                  ]),
                const SizedBox(height: 48),
                composer,
                Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
                  Expanded(child: Align(alignment: Alignment.centerLeft,
                    child: machinePicker ?? PopupMenuButton<String>(tooltip: 'Checkout options', enabled: project != null,
                    onSelected: (value) {
                      if (value == 'trace') session.chooseTracing(!session.currentDraft.tracing);
                      onReturnFocus();
                    },
                    itemBuilder: (_) => [
                      if (project != null) PopupMenuItem<String>(enabled: false, child: Text(project.path)),
                      CheckedPopupMenuItem(value: 'trace', checked: session.currentDraft.tracing,
                        enabled: !session.submitting, child: const Text('Trace this session')),
                    ],
                    child: MouseRegion(cursor: project != null ? SystemMouseCursors.click : SystemMouseCursors.basic,
                      child: const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.folder_outlined, size: 13, color: desktopSecondary), SizedBox(width: 6),
                      Text('Current checkout', style: TextStyle(fontSize: 12, color: desktopSecondary)),
                    ])))))),
                  if (machinePicker == null && project != null) Flexible(child: CheckoutPullControl(session: session)),
                  if (machinePicker != null) SizedBox(width: 28, height: 28, child: PopupMenuButton<String>(tooltip: 'Thread options',
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.more_horiz, size: 16, color: desktopSecondary),
                    onSelected: (_) { session.chooseTracing(!session.currentDraft.tracing); onReturnFocus(); },
                    itemBuilder: (_) => [CheckedPopupMenuItem(value: 'trace', checked: session.currentDraft.tracing,
                      enabled: !session.submitting, child: const Text('Trace this session'))])),
                  if (project?.branch case final branch?) ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: bounds.maxWidth * .3),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.fork_right_rounded, size: 14, color: desktopSecondary),
                    const SizedBox(width: 6),
                    Flexible(child: Text(branch, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: desktopSecondary))),
                  ])),
                ])),
                if (project?.removing == true)
                  const Padding(padding: EdgeInsets.all(12), child: Text('Removing project…', style: TextStyle(fontSize: 13, color: desktopTertiary)))
                else if (project?.available == false)
                  Padding(padding: const EdgeInsets.all(12), child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
                    const Text('Project folder is unavailable. Choose another project.', style: TextStyle(fontSize: 13, color: desktopTertiary)),
                    TextButton(onPressed: () => onRemoveProject(project!), child: const Text('Remove project')),
                  ])),
              ])))))),
        if (project != null && bounds.maxWidth >= 1100 && bounds.maxHeight >= 700)
          Positioned(top: 12, right: 12, child: SizedBox(width: 288, child: Material(
            color: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xffe8e8eb))),
            clipBehavior: Clip.antiAlias,
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(dense: true, minTileHeight: 34, contentPadding: const EdgeInsets.symmetric(horizontal: 18),
                minLeadingWidth: 16, horizontalTitleGap: 12,
                leading: const Icon(Icons.computer_outlined, size: 16),
                title: Text(machineLabel(session), style: const TextStyle(fontSize: 13))),
              if (onOpenFolder != null) ListTile(dense: true, minTileHeight: 34,
                minLeadingWidth: 16, horizontalTitleGap: 12,
                contentPadding: const EdgeInsets.symmetric(horizontal: 18), onTap: onOpenFolder,
                leading: const Icon(Icons.folder_open_outlined, size: 16),
                title: Text(Theme.of(context).platform == TargetPlatform.macOS ? 'Open in Finder' : 'Open folder',
                  style: const TextStyle(fontSize: 13))),
              if (project.branch case final branch?) ...[
                const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Divider(height: 1)),
                ListTile(dense: true, minTileHeight: 34, contentPadding: const EdgeInsets.symmetric(horizontal: 18),
                  minLeadingWidth: 16, horizontalTitleGap: 12,
                  leading: const Icon(Icons.fork_right_rounded, size: 16),
                  title: Text(branch, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
              ],
            ]))))),
      ]));
    });
  }
}

class _ProjectPicker extends StatefulWidget {
  const _ProjectPicker({required this.projects, required this.selected, required this.onSelect, required this.onAdd,
    required this.onRemove, required this.generated});
  final List<DesktopProject> projects;
  final String? selected;
  final ValueChanged<Project> onSelect, onRemove;
  final VoidCallback onAdd;
  final bool generated;

  @override
  State<_ProjectPicker> createState() => _ProjectPickerState();
}

class _ProjectPickerState extends State<_ProjectPicker> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  int _active = 0;

  List<DesktopProject> get _projects {
    final query = _search.text.trim().toLowerCase();
    return widget.projects.where((project) => desktopProjectSearchText(project).toLowerCase().contains(query)).toList()
      ..sort((a, b) => desktopProjectActivity(b).compareTo(desktopProjectActivity(a)));
  }

  @override
  void initState() {
    super.initState();
    _active = _projects.indexWhere((project) => project.id == widget.selected).clamp(0, widget.projects.length);
  }

  @override
  void dispose() { _search.dispose(); _scroll.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final projects = _projects;
    void select() {
      if (_active == projects.length) { widget.onAdd(); }
      else if (projects[_active].preferred.project.available) { widget.onSelect(projects[_active].preferred.project); }
    }
    return SizedBox(width: 360, child: Focus(onKeyEvent: (_, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
      final key = event.logicalKey;
      if ((key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.delete) &&
          SingleActivator(key, meta: true).accepts(event, HardwareKeyboard.instance)) {
        if (event is KeyDownEvent && _active < projects.length) widget.onRemove(projects[_active].preferred.project);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter) { select(); return KeyEventResult.handled; }
      if (key != LogicalKeyboardKey.arrowDown && key != LogicalKeyboardKey.arrowUp) return KeyEventResult.ignored;
      setState(() {
        do {
          _active = (_active + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) % (projects.length + 1);
        } while (_active < projects.length && !projects[_active].preferred.project.available);
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
        ? const Padding(padding: EdgeInsets.all(24), child: Text('No projects found.', style: TextStyle(fontSize: 13, color: desktopTertiary)))
        // MenuAnchor measures intrinsic dimensions, which viewports cannot supply.
        // Bound the list by its row heights and padding instead of shrink-wrapping.
        : SizedBox(height: (projects.length * 48.0 + 8).clamp(0.0, 288.0),
          child: ListView(controller: _scroll, padding: const EdgeInsets.all(4), itemExtent: 48, children: [
              for (var index = 0; index < projects.length; index++)
                _row(projects[index].preferred.project.name, projects[index].preferred.project.available
                    ? desktopProjectDescription(projects[index]) : 'Folder unavailable · ${desktopProjectDescription(projects[index])}',
                  ProjectAvatar(project: projects[index].preferred.project, size: 20, generated: widget.generated), active: _active == index,
                  selected: projects[index].id == widget.selected, enabled: projects[index].preferred.project.available,
                  onTap: () => widget.onSelect(projects[index].preferred.project)),
            ]))),
      const Divider(height: 1),
      Padding(padding: const EdgeInsets.all(4), child: _row('Add project', null,
        const Icon(Icons.create_new_folder_outlined, size: 18, color: desktopSecondary),
        active: _active == projects.length, onTap: widget.onAdd)),
    ])));
  }

  Widget _row(String title, String? subtitle, Widget icon, {required bool active,
    bool selected = false, bool enabled = true, required VoidCallback onTap}) => Material(
    color: active ? desktopMuted : Colors.transparent, borderRadius: BorderRadius.circular(4),
    child: InkWell(onTap: enabled ? onTap : null, borderRadius: BorderRadius.circular(4),
      mouseCursor: WidgetStateMouseCursor.clickable,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), child: Opacity(
        opacity: enabled ? 1 : .45, child: Row(children: [
          icon, const SizedBox(width: 10), Expanded(child: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, height: 16 / 13, color: desktopForeground)),
              if (subtitle != null) Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, height: 16 / 11, color: desktopTertiary)),
            ])),
          if (selected) const Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.check_rounded, size: 14, color: desktopSecondary)),
        ])))));
}
