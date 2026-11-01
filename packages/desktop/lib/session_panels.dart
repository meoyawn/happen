import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'context_window.dart';
import 'panel_state.dart';
import 'session.dart';
import 'sidebar_resizer.dart';
import 'window_chrome.dart';

/// OpenCode's side region is a sibling of the entire chat, including its composer.
/// Hiding a region retains its tabs; closing a tab releases its content and reads.
class SessionPanelWorkspace extends StatefulWidget {
  const SessionPanelWorkspace({super.key, required this.session, required this.task,
    required this.child, required this.onReturnFocus});
  final DesktopSession session;
  final DesktopTask? task;
  final Widget child;
  final VoidCallback onReturnFocus;

  @override
  State<SessionPanelWorkspace> createState() => _SessionPanelWorkspaceState();
}

class _SessionPanelWorkspaceState extends State<SessionPanelWorkspace> {
  final _lifetime = CancellationToken();
  final _focus = FocusScopeNode(debugLabel: 'Session side panel');
  double? _dragWidth;

  @override
  void initState() {
    super.initState();
    unawaited(widget.session.loadPanelLayouts(_lifetime).catchError((Object error) {
      if (!_lifetime.isCancelled) widget.session.showError(error);
    }));
  }

  @override
  void didUpdateWidget(covariant SessionPanelWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task != widget.task) _dragWidth = null;
  }

  @override
  void dispose() { _lifetime.cancel(); _focus.dispose(); super.dispose(); }

  void _close(String tab) {
    widget.session.closeSessionPanel(widget.task!, tab);
    if (!widget.session.panelsFor(widget.task!).opened) widget.onReturnFocus();
  }

  void _hide() {
    widget.session.toggleSidePanel(widget.task!);
    widget.onReturnFocus();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.session,
    child: widget.child, builder: (context, child) => LayoutBuilder(builder: (context, bounds) {
      final task = widget.task;
      final state = task == null ? null : widget.session.panelsFor(task);
      final opened = state?.opened == true;
      final wide = bounds.maxWidth >= 768;
      final available = bounds.maxWidth - 8;
      final resized = _dragWidth != null || state?.sessionWidth != null;
      final minimum = resized ? 400.0 : 450.0;
      final reserve = resized ? 320.0 : 480.0;
      final maximum = math.max(minimum, available - reserve);
      final chatWidth = (_dragWidth ?? state?.sessionWidth ?? 600).clamp(400, maximum).toDouble();
      final sideWidth = wide ? math.max(320.0, available - chatWidth) : bounds.maxWidth;
      return Stack(fit: StackFit.expand, children: [
        Positioned.fill(right: opened && wide ? sideWidth + 8 : 0,
          child: Offstage(offstage: opened && !wide, child: child!)),
        if (state != null && state.tabs.isNotEmpty)
          Positioned(top: 0, right: 0, bottom: 0, width: sideWidth,
            child: Offstage(offstage: !opened, child: ExcludeFocus(excluding: !opened,
              child: FocusScope(node: _focus, child: CallbackShortcuts(bindings: {
                SingleActivator(LogicalKeyboardKey.keyW,
                  meta: defaultTargetPlatform == TargetPlatform.macOS,
                  control: defaultTargetPlatform != TargetPlatform.macOS):
                    () { if (state.active case final tab?) _close(tab); },
              }, child: SessionPanelFrame(key: const ValueKey('session-side-region'), child: Column(children: [
                _strip(state),
                Expanded(child: Stack(fit: StackFit.expand, children: [
                  if (state.tabs.contains(contextPanel))
                    Offstage(offstage: state.active != contextPanel,
                      child: SessionContextWindow(key: ValueKey('context:${task!.id}'),
                        session: widget.session, task: task)),
                  if (state.active?.startsWith('new:') == true) _launchers(state),
                ])),
              ]))))))),
        if (opened && wide) Positioned(left: chatWidth - 4, top: 0, bottom: 0, width: 8,
          child: SidebarResizer(key: const ValueKey('session-panel-resizer'),
            label: 'Resize session panels', size: chatWidth, min: 400,
            max: math.max(400.0, available - 320),
            onResize: (width) => setState(() => _dragWidth = width),
            onResizeEnd: (width) {
              widget.session.resizeSessionPanel(task!, width);
              setState(() => _dragWidth = null);
            },
            onCancel: () => setState(() => _dragWidth = null))),
      ]);
    }));

  Widget _strip(SessionPanelState state) => DesktopWindowDragRegion(child: Container(
    height: 48,
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: opencodeBorder, width: .5))),
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(children: [
      Expanded(child: LayoutBuilder(builder: (context, bounds) {
        final width = (bounds.maxWidth / state.tabs.length).clamp(80.0, 190.0);
        return SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          for (final tab in state.tabs) SizedBox(width: width, child: _PanelTab(
            key: ValueKey(tab), title: tab == contextPanel ? 'Context' : 'New tab',
            icon: tab == contextPanel ? Icons.donut_large_rounded : Icons.add_rounded,
            active: state.active == tab,
            onSelect: () => widget.session.selectSessionPanel(widget.task!, tab),
            onClose: () => _close(tab),
            onMenu: (position) => _tabMenu(state, tab, position))),
        ]));
      })),
      _panelButton('Add tab', Icons.add_rounded, () => widget.session.newSessionPanelTab(widget.task!)),
      const SizedBox(width: 4),
      SizedBox.square(dimension: 28, child: IconButton(key: const ValueKey('toggle-side-panel'),
        tooltip: 'Hide side panel (${defaultTargetPlatform == TargetPlatform.macOS ? '⌘B' : 'Ctrl+B'})', onPressed: _hide,
        padding: EdgeInsets.zero, icon: const SidePanelIcon(opened: true))),
    ]),
  ));

  Future<void> _tabMenu(SessionPanelState state, String tab, Offset position) async {
    final task = widget.task;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<String>(context: context,
      position: RelativeRect.fromRect(position & Size.zero, Offset.zero & overlay.size),
      items: [const PopupMenuItem(value: 'close', child: Text('Close tab')),
        PopupMenuItem(value: 'others', enabled: state.tabs.length > 1, child: const Text('Close other tabs'))]);
    if (!mounted || widget.task != task) return;
    if (action == 'close') _close(tab);
    if (action == 'others') {
      for (final other in state.tabs.toList()) { if (other != tab) _close(other); }
    }
  }

  Widget _launchers(SessionPanelState state) => ListView(
    key: ValueKey('panel-launchers:${widget.task!.id}'),
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28), children: [
      const Text('Open a panel', style: TextStyle(fontSize: 13, color: opencodeMuted)),
      const SizedBox(height: 16),
      ListTile(key: const ValueKey('open-context-panel'), contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.donut_large_rounded, size: 18, color: opencodeMuted),
        title: const Text('Context', style: TextStyle(fontSize: 13)),
        subtitle: const Text('Usage, system prompt, and raw messages', style: TextStyle(fontSize: 12, color: opencodeFaint)),
        trailing: const Icon(Icons.chevron_right_rounded, size: 16, color: opencodeFaint),
        onTap: () => widget.session.openSessionPanel(widget.task!, contextPanel)),
      if (state.closed.isNotEmpty) ...[
        const SizedBox(height: 28),
        const Text('Recently closed', style: TextStyle(fontSize: 12, color: opencodeFaint)),
        for (final tab in state.closed) ListTile(contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.history_rounded, size: 16, color: opencodeFaint),
          title: const Text('Context', style: TextStyle(fontSize: 13)),
          onTap: () => widget.session.openSessionPanel(widget.task!, tab)),
      ],
    ],
  );
}

class SessionPanelFrame extends StatelessWidget {
  const SessionPanelFrame({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10),
      border: Border.all(color: opencodeBorder, width: .5),
      boxShadow: const [BoxShadow(color: Color(0x0a000000), blurRadius: 3, offset: Offset(0, 1))]),
    child: Material(color: Colors.white, child: child));
}

class SidePanelIcon extends StatelessWidget {
  const SidePanelIcon({super.key, required this.opened});
  final bool opened;
  @override
  Widget build(BuildContext context) => CustomPaint(size: const Size(16, 16), painter: _SidePanelGlyph(opened));
}

class _SidePanelGlyph extends CustomPainter {
  const _SidePanelGlyph(this.opened);
  final bool opened;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = opencodeFaint..style = PaintingStyle.stroke..strokeWidth = 1.3;
    canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(1.5, 2.5, 13, 11), const Radius.circular(1.5)), paint);
    canvas.drawLine(const Offset(9.5, 2.5), const Offset(9.5, 13.5), paint);
    if (opened) canvas.drawRect(const Rect.fromLTWH(10.3, 3.3, 3.4, 9.4), paint..style = PaintingStyle.fill);
  }
  @override
  bool shouldRepaint(_SidePanelGlyph oldDelegate) => opened != oldDelegate.opened;
}

class _PanelTab extends StatelessWidget {
  const _PanelTab({super.key, required this.title, required this.icon, required this.active,
    required this.onSelect, required this.onClose, required this.onMenu});
  final String title;
  final IconData icon;
  final bool active;
  final VoidCallback onSelect, onClose;
  final ValueChanged<Offset> onMenu;
  @override
  Widget build(BuildContext context) => Semantics(selected: active, button: true, label: title,
    child: GestureDetector(onTertiaryTapUp: (_) => onClose(), onSecondaryTapUp: (event) => onMenu(event.globalPosition),
      child: Material(color: active ? opencodeLayer : Colors.transparent, borderRadius: BorderRadius.circular(6),
        child: InkWell(onTap: onSelect, borderRadius: BorderRadius.circular(6), child: SizedBox(height: 32,
          child: Padding(padding: const EdgeInsets.only(left: 10, right: 4), child: Row(children: [
            Icon(icon, size: 14, color: active ? opencodeInk : opencodeFaint),
            const SizedBox(width: 8),
            Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: active ? opencodeInk : opencodeMuted))),
            _panelButton('Close tab', Icons.close_rounded, onClose),
          ])))))));
}

Widget _panelButton(String label, IconData icon, VoidCallback onPressed) => SizedBox.square(dimension: 28,
  child: IconButton(tooltip: label, onPressed: onPressed, padding: EdgeInsets.zero,
    style: IconButton.styleFrom(minimumSize: const Size.square(28), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
    icon: Icon(icon, size: 16, color: opencodeMuted)));
