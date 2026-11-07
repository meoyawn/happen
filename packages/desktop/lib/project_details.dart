// Workspace and Git sections follow T3 Code ThreadDetailsPanel.tsx, 86d8838e9.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'details_row.dart';
import 'diff_viewer.dart';
import 'git_actions.dart';
import 'git_actions_state.dart';
import 'git_branch_dialog.dart';
import 'panel_state.dart';
import 'project_actions_state.dart';
import 'project_script_dialog.dart';
import 'session.dart';
import 'workspace_changes.dart';

/// The details card sits beside the conversation when there is room, and floats
/// under its toolbar button in smaller windows.
class ProjectDetailsWorkspace extends StatefulWidget {
  const ProjectDetailsWorkspace({super.key, required this.session, required this.header, required this.child});
  final DesktopSession session;
  final Widget Function(bool opened, VoidCallback toggle) header;
  final Widget child;
  @override
  State<ProjectDetailsWorkspace> createState() => _ProjectDetailsWorkspaceState();
}

class _ProjectDetailsWorkspaceState extends State<ProjectDetailsWorkspace> {
  bool? _opened;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, bounds) {
    final project = widget.session.project;
    final available = project?.available == true && project?.removing != true;
    final inline = bounds.maxWidth >= 920;
    final opened = available && (_opened ?? inline);
    void toggle() => setState(() => _opened = !opened);
    final card = project == null ? const SizedBox.shrink() : ProjectDetailsCard(
      key: ValueKey(project.checkoutKey), session: widget.session, project: project);
    return Column(children: [
      widget.header(opened, toggle),
      Expanded(child: inline ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: widget.child),
        if (opened) SizedBox(width: 292, child: Padding(padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
          child: card)),
      ]) : Stack(fit: StackFit.expand, children: [
        widget.child,
        if (opened) ...[
          Positioned.fill(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: toggle)),
          Positioned(top: 12, right: 12, width: 280, bottom: 12,
            child: Align(alignment: Alignment.topRight, child: card)),
        ],
      ])),
    ]);
  });
}

class WorkspacePanelButton extends StatelessWidget {
  const WorkspacePanelButton({super.key, required this.tooltip, required this.opened, required this.icon, this.onPressed});
  final String tooltip;
  final bool opened;
  final Widget icon;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Semantics(toggled: opened, child: IconButton(
    tooltip: tooltip, onPressed: onPressed, icon: icon,
    style: IconButton.styleFrom(foregroundColor: const Color(0xff4d4f53),
      backgroundColor: opened ? desktopMuted : Colors.transparent,
      minimumSize: const Size(28, 28), maximumSize: const Size(28, 28), padding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap)));
}

class BottomPanelIcon extends StatelessWidget {
  const BottomPanelIcon({super.key});
  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(16, 16), painter: _BottomPanelPainter());
}
class _BottomPanelPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()..color = const Color(0xff4d4f53)..style = PaintingStyle.stroke..strokeWidth = 1.3;
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(1.5, 1.5, 13, 13), const Radius.circular(1.5)), pen);
    canvas.drawLine(const Offset(1.5, 10), const Offset(14.5, 10), pen);
  }
  @override
  bool shouldRepaint(_BottomPanelPainter oldDelegate) => false;
}

class ProjectDetailsCard extends StatefulWidget {
  const ProjectDetailsCard({super.key, required this.session, required this.project});
  final DesktopSession session;
  final Project project;
  @override
  State<ProjectDetailsCard> createState() => _ProjectDetailsCardState();
}

class _ProjectDetailsCardState extends State<ProjectDetailsCard> {
  final _lifetime = CancellationToken();
  GitActionsController get git => widget.session.gitForProject(widget.project);
  ProjectActionsController get actions => widget.session.actionsForProject(widget.project);
  @override
  void initState() { super.initState(); unawaited(actions.load()); }
  @override
  void dispose() { _lifetime.cancel(); super.dispose(); }

  Future<void> _effect(Future<void> Function() action) async {
    try { await action(); }
    on CancelledException { /* The card or session closed. */ }
    catch (error) { widget.session.showError(error); }
  }

  Future<void> _open(ProjectOpener target) async {
    await actions.open(target, _lifetime);
    if (actions.opener.id != target.id) {
      await actions.save((opener: target.id, scripts: actions.state.value.scripts), _lifetime);
    }
  }

  Future<void> _branch() async {
    final controller = git;
    if (controller.busy || widget.project.tasks.any((task) => task.running)) return;
    final selection = await showDialog<BranchSelection>(context: context,
      builder: (context) => GitBranchDialog(controller: controller));
    if (selection != null) await controller.run(selection.create ? 'create_branch' : 'switch', branch: selection.branch);
  }

  void _editScript([ProjectScript? script]) => unawaited(showDialog<void>(context: context,
    builder: (context) => ProjectScriptDialog(controller: actions, script: script)));
  void _runScript(ProjectScript script) {
    widget.session.terminals.runScript((widget.project.checkoutKey, widget.session.draftKey),
      widget.project.path, script.name, script.command);
  }
  void _changes() {
    final task = widget.session.task;
    if (task != null) {
      widget.session.openSessionPanel(task, workspaceChangesPanel, toggle: true);
    } else {
      unawaited(showDialog<void>(context: context, builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias, child: SizedBox(width: 1000, height: 720, child: Column(children: [
          Align(alignment: Alignment.centerRight, child: IconButton(tooltip: 'Close changes',
            onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, size: 18))),
          Expanded(child: WorkspaceChanges(controller: git)),
        ])))));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: Listenable.merge([git, actions]), builder: (context, _) {
    final repo = git.state.repository;
    final settingsReady = actions.state is ProjectActionsReady || actions.state is ProjectActionsFailed;
    final local = actions.local && widget.project.available;
    final scripts = actions.state.value.scripts;
    final canRun = local && widget.session.task?.archived != true && widget.session.task?.archiving != true;
    final host = (repo?.host ?? (local ? Platform.localHostname : 'Server')).replaceFirst(RegExp(r'\.local$'), '');
    return Material(key: const ValueKey('project-details-card'), color: Colors.white, clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xffe5e5e5))),
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.all(12), child: Column(mainAxisSize: MainAxisSize.min, children: [
          DetailsRow(icon: const Icon(Icons.laptop_mac_outlined), label: host, tooltip: widget.project.path,
            trailing: IconButton(tooltip: 'Open project folder', style: detailsMenuStyle,
              onPressed: local ? () => unawaited(_effect(() => actions.open(actions.openers.first, _lifetime))) : null,
              icon: const Icon(Icons.folder_outlined, size: 17))),
          DetailsRow(icon: actions.opener.id == 'files' && Platform.isMacOS
              ? const _FinderIcon() : const Icon(Icons.open_in_new_rounded),
            label: 'Open in ${actions.opener.label}', onPressed: local && settingsReady
              ? () => unawaited(_effect(() => _open(actions.opener))) : null,
            tooltip: local ? widget.project.path : 'Opening applications requires a shared filesystem',
            trailing: PopupMenuButton<String>(tooltip: 'Choose application', enabled: local && settingsReady,
              icon: detailsChevron, style: detailsMenuStyle,
              onSelected: (id) {
                if (id == 'copy') { unawaited(Clipboard.setData(ClipboardData(text: widget.project.path))); }
                else { unawaited(_effect(() => _open(actions.openers.firstWhere((target) => target.id == id)))); }
              },
              itemBuilder: (context) => [
                for (final target in actions.openers) PopupMenuItem(value: target.id, child: Row(children: [
                  Expanded(child: Text(target.label)),
                  if (actions.opener.id == target.id) const Icon(Icons.check_rounded, size: 16),
                ])),
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'copy', child: Text('Copy project path')),
              ])),
          DetailsRow(icon: Icon(scripts.isEmpty ? Icons.add_rounded : Icons.play_arrow_outlined),
            label: scripts.isEmpty ? 'Add project script' : scripts.first.name,
            onPressed: !settingsReady || !local ? null : scripts.isEmpty ? _editScript : canRun ? () => _runScript(scripts.first) : null,
            tooltip: scripts.isEmpty ? 'Save a command for this project' : scripts.first.command,
            trailing: scripts.isEmpty ? null : PopupMenuButton<String>(tooltip: 'Project scripts',
              icon: detailsChevron, style: detailsMenuStyle, enabled: settingsReady && local,
              onSelected: (value) {
                if (value == 'add') { _editScript(); return; }
                final id = value.substring(value.indexOf(':') + 1);
                final script = scripts.firstWhere((script) => script.id == id);
                if (value.startsWith('edit:')) { _editScript(script); } else { _runScript(script); }
              },
              itemBuilder: (context) => [
                for (final script in scripts) ...[
                  PopupMenuItem(value: 'run:${script.id}', enabled: canRun,
                    child: Text('Run ${script.name}', maxLines: 1, overflow: TextOverflow.ellipsis)),
                  PopupMenuItem(value: 'edit:${script.id}',
                    child: Text('Edit ${script.name}…', maxLines: 1, overflow: TextOverflow.ellipsis)),
                ],
                const PopupMenuDivider(),
                const PopupMenuItem(value: 'add', child: Text('Add project script')),
              ])),
          if (actions.state case ProjectActionsFailed(:final message))
            Padding(padding: const EdgeInsets.all(8), child: Text(message,
              style: const TextStyle(fontSize: 11, color: desktopError))),
        ])),
        if (repo?.isRepo == true || git.state is GitLoading || git.state is GitFailed) ...[
          const Divider(height: 1, thickness: 1, color: desktopBorder),
          Padding(padding: const EdgeInsets.all(12), child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (repo?.isRepo == true) DetailsRow(icon: const Icon(Icons.call_split_rounded),
              label: repo!.branch ?? 'Detached HEAD', tooltip: widget.project.tasks.any((task) => task.running)
                ? 'Wait for the running thread before switching branches'
                : '${repo.ahead} ahead · ${repo.behind} behind${repo.upstream == null ? '' : ' · ${repo.upstream}'}',
              onPressed: git.busy || widget.project.tasks.any((task) => task.running) ? null : () => unawaited(_effect(_branch)),
              trailing: IconButton(tooltip: 'Choose branch', style: detailsMenuStyle,
                onPressed: git.busy || widget.project.tasks.any((task) => task.running) ? null : () => unawaited(_effect(_branch)),
                icon: detailsChevron)),
            GitActionsControl(controller: git, provider: widget.session.providerId, model: widget.session.modelId),
            if (repo?.isRepo == true) DetailsRow(icon: const Icon(Icons.note_add_outlined), label: 'Changes',
              onPressed: _changes, tooltip: '${repo!.files.length} changed files · Compared with HEAD',
              trailing: Padding(padding: const EdgeInsets.only(right: 8), child: repo.additions == 0 && repo.deletions == 0
                ? Text('${repo.files.length} files', style: const TextStyle(fontSize: 11, color: desktopTertiary))
                : DiffStat(additions: repo.additions, deletions: repo.deletions))),
          ])),
        ],
      ])));
  });
}

class _FinderIcon extends StatelessWidget {
  const _FinderIcon();
  @override
  Widget build(BuildContext context) => CustomPaint(painter: _FinderPainter());
}
class _FinderPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save(); canvas.scale(size.width / 16, size.height / 16);
    final outline = RRect.fromRectAndRadius(const Rect.fromLTWH(1, 0, 14, 16), const Radius.circular(3));
    canvas.clipRRect(outline);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 16, 16), Paint()..color = const Color(0xffd9f0ff));
    canvas.drawRect(const Rect.fromLTWH(0, 0, 8, 16), Paint()..color = const Color(0xff3aaaf5));
    final pen = Paint()..color = const Color(0xff103b52)..style = PaintingStyle.stroke..strokeWidth = .85..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(4, 4), const Offset(4, 6), pen);
    canvas.drawLine(const Offset(12, 4), const Offset(12, 6), pen);
    canvas.drawPath(Path()..moveTo(9, 1)..lineTo(7, 9)..lineTo(9, 9)..lineTo(9, 15), pen);
    canvas.drawPath(Path()..moveTo(4, 10)..quadraticBezierTo(8, 13.5, 12, 10), pen);
    canvas.restore();
  }
  @override
  bool shouldRepaint(_FinderPainter oldDelegate) => false;
}
