import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'browser.dart';
import 'context_window.dart';
import 'conversation.dart';
import 'conversation_data.dart';
import 'file_icon.dart';
import 'file_reference.dart';
import 'file_viewer.dart';
import 'panel_state.dart';
import 'session.dart';
import 'sidebar_resizer.dart';
import 'window_chrome.dart';

/// OpenCode's side region is a sibling of the entire chat, including its composer.
/// Hiding a region retains its tabs; closing a tab releases its content and reads.
class SessionPanelWorkspace extends StatefulWidget {
  const SessionPanelWorkspace({super.key, required this.session, required this.task,
    required this.child, required this.onReturnFocus, required this.sideComposer});
  final DesktopSession session;
  final DesktopTask? task;
  final Widget child;
  final VoidCallback onReturnFocus;
  final Widget Function(DesktopTask task, bool active) sideComposer;

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

  void _openFile(ConversationFileLocation location) {
    final task = widget.task;
    if (task != null) {
      widget.session.openSessionPanel(task, 'file:${location.path}', line: location.line);
    } else {
      unawaited(showDialog<void>(context: context, builder: (context) => ConversationFileScope(
        onOpen: _openFile, child: Dialog(
        clipBehavior: Clip.antiAlias, child: SizedBox(width: 900, height: 700,
          child: Column(children: [
            Row(children: [
              const SizedBox(width: 16), FileIcon(location.path), const SizedBox(width: 8),
              Expanded(child: Text(_panelTitle('file:${location.path}'),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
              IconButton(tooltip: 'Close file viewer', icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () => Navigator.of(context).pop()),
            ]),
            Expanded(child: FileViewer(path: location.path, line: location.line)),
          ]))))));
    }
  }

  void _openBrowser(Uri uri) {
    if (widget.task case final task?) {
      widget.session.openBrowserPanel(task, url: uri.toString());
    } else {
      unawaited(showDialog<void>(context: context, builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias, child: SizedBox(width: 1000, height: 700,
          child: Column(children: [
            Align(alignment: Alignment.centerRight, child: IconButton(
              tooltip: 'Close browser', icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => Navigator.of(context).pop())),
            Expanded(child: DesktopBrowser(initialUrl: uri.toString())),
          ])))));
    }
  }

  @override
  Widget build(BuildContext context) => ConversationBrowserScope(onOpen: _openBrowser,
    child: ConversationFileScope(onOpen: _openFile,
    child: ListenableBuilder(listenable: widget.session,
    child: widget.child, builder: (context, child) => LayoutBuilder(builder: (context, bounds) {
      final task = widget.task;
      final state = task == null ? null : widget.session.panelsFor(task);
      final directory = widget.session.projects.where((project) => project.tasks.contains(task)).firstOrNull?.path;
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
                        session: widget.session, task: task, onAttached: widget.onReturnFocus)),
                  for (final tab in state.tabs.where(isFilePanel))
                    Offstage(key: ValueKey((task!.id, tab)), offstage: state.active != tab,
                      child: ExcludeFocus(excluding: state.active != tab,
                      child: FileViewer(path: filePanelPath(tab),
                        directory: directory,
                        active: opened && state.active == tab, line: state.fileReveals[tab]?.line,
                        revealRequest: state.fileReveals[tab]?.revision ?? 0))),
                  for (final tab in state.tabs.where(isBrowserPanel))
                    Offstage(key: ValueKey((task!.id, tab)), offstage: state.active != tab,
                      child: ExcludeFocus(excluding: !opened || state.active != tab,
                        child: DesktopBrowser(initialUrl: state.browserPages[tab]?.url ?? '',
                          active: opened && state.active == tab, directory: directory,
                          onNewTab: () => widget.session.openBrowserPanel(task),
                          onPageChanged: (url, title) => widget.session.updateBrowserPanel(task, tab, url, title)))),
                  for (final tab in state.tabs.where(isSideChatPanel))
                    if (widget.session.sideChats[sideChatID(tab)] case final side?)
                      Offstage(key: ValueKey((task!.id, side.draftKey)), offstage: state.active != tab,
                        child: ExcludeFocus(excluding: !opened || state.active != tab,
                          child: TickerMode(enabled: opened && state.active == tab,
                            child: _sideChat(side, opened && state.active == tab)))),
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
    }))));

  Widget _sideChat(DesktopTask side, bool active) => Column(children: [
    const Padding(padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Align(alignment: Alignment.centerLeft, child: Text('Temporary side chat',
        style: TextStyle(fontSize: 12, color: opencodeFaint)))),
    Expanded(child: side.sidePreparing
      ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(
          mainAxisSize: MainAxisSize.min, children: [
            if (side.sideError == null)
              const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
            else const Icon(Icons.error_outline_rounded, color: opencodeFaint),
            const SizedBox(height: 12),
            Text(side.sideError == null ? 'Preparing side chat…' : 'Couldn’t prepare side chat',
              style: const TextStyle(fontSize: 14, color: opencodeMuted)),
            if (side.sideError == null) ...[
              const SizedBox(height: 6),
              const Text('You can start typing below.',
                style: TextStyle(fontSize: 12, color: opencodeFaint)),
            ],
          ])))
      : side.loaded && side.messages.isEmpty && !side.running
      ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Column(
          mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.chat_bubble_outline_rounded, size: 24, color: opencodeFaint),
            SizedBox(height: 12),
            Text('Ask a side question', style: TextStyle(fontSize: 14, color: opencodeMuted)),
            SizedBox(height: 6),
            Text('Uses a snapshot of the main conversation.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: opencodeFaint)),
          ])))
      : ConversationDataScope(client: widget.session.client, providers: widget.session.providers,
          child: ConversationTranscript(key: ValueKey(side.id), task: side,
            directory: widget.session.projects.where((project) =>
              project.tasks.contains(widget.task)).firstOrNull?.path ?? '',
            onRetry: () => unawaited(widget.session.loadHistory(side)),
            onRetryTurn: () => unawaited(widget.session.retry(side).catchError((Object error) =>
              widget.session.showError(error, target: side))),
            onLoadEarlier: () => unawaited(widget.session.loadEarlier(side)),
            onPendingAction: widget.session.changePending))),
    if (side.sideError case final error?) Padding(padding: const EdgeInsets.symmetric(horizontal: 20),
      child: SelectableText(error, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error))),
    widget.sideComposer(side, active),
  ]);

  Widget _strip(SessionPanelState state) => DesktopWindowDragRegion(child: Container(
    height: 48,
    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: opencodeBorder, width: .5))),
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(children: [
      Expanded(child: LayoutBuilder(builder: (context, bounds) {
        final width = (bounds.maxWidth / state.tabs.length).clamp(80.0, 190.0);
        return SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          for (final tab in state.tabs) SizedBox(width: width, child: _PanelTab(
            key: ValueKey(tab), title: isSideChatPanel(tab)
              ? widget.session.sideChats[sideChatID(tab)]?.title ?? 'Side chat' : _panelTitle(tab, state),
            icon: isFilePanel(tab) ? FileIcon(filePanelPath(tab), size: 14)
              : Icon(tab == contextPanel ? Icons.donut_large_rounded
                  : isBrowserPanel(tab) ? Icons.language_rounded
                  : isSideChatPanel(tab) ? Icons.chat_bubble_outline_rounded : Icons.add_rounded,
                  size: 14, color: state.active == tab ? opencodeInk : opencodeFaint),
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
      ListTile(key: const ValueKey('open-browser-panel'), contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.language_rounded, size: 18, color: opencodeMuted),
        title: const Text('Browser', style: TextStyle(fontSize: 13)),
        subtitle: const Text('Preview your app, read docs, or browse the web',
          style: TextStyle(fontSize: 12, color: opencodeFaint)),
        trailing: const Icon(Icons.chevron_right_rounded, size: 16, color: opencodeFaint),
        onTap: () => widget.session.openBrowserPanel(widget.task!)),
      ListTile(key: const ValueKey('open-side-chat'), contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.chat_bubble_outline_rounded, size: 18, color: opencodeMuted),
        title: const Text('Side chat', style: TextStyle(fontSize: 13)),
        subtitle: const Text('Ask a question with context from this session',
          style: TextStyle(fontSize: 12, color: opencodeFaint)),
        trailing: const Icon(Icons.chevron_right_rounded, size: 16, color: opencodeFaint),
        enabled: widget.session.connected && !widget.task!.archived && !widget.task!.archiving,
        onTap: () => unawaited(() async {
          try { await widget.session.openSideChat(widget.task!); }
          on CancelledException { /* The pending side chat was closed. */ }
          catch (error) { widget.session.showError(error); }
        }())),
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
          title: Text(_panelTitle(tab, state), maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13)),
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
  final Widget icon;
  final bool active;
  final VoidCallback onSelect, onClose;
  final ValueChanged<Offset> onMenu;
  @override
  Widget build(BuildContext context) => Semantics(selected: active, button: true, label: title,
    child: GestureDetector(onTertiaryTapUp: (_) => onClose(), onSecondaryTapUp: (event) => onMenu(event.globalPosition),
      child: Material(color: active ? opencodeLayer : Colors.transparent, borderRadius: BorderRadius.circular(6),
        child: InkWell(onTap: onSelect, borderRadius: BorderRadius.circular(6), child: SizedBox(height: 32,
          child: Padding(padding: const EdgeInsets.only(left: 10, right: 4), child: Row(children: [
            icon,
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

String _panelTitle(String tab, [SessionPanelState? state]) => tab == contextPanel ? 'Context'
  : isFilePanel(tab) ? filePanelPath(tab).split('/').where((part) => part.isNotEmpty).lastOrNull ?? '/'
  : isBrowserPanel(tab) ? _browserTitle(state?.browserPages[tab])
  : 'New tab';

String _browserTitle(({String url, String title})? page) {
  if (page == null || page.url.isEmpty || page.url == 'about:blank') return 'Browser';
  if (page.title.isNotEmpty) return page.title;
  final uri = Uri.tryParse(page.url);
  return uri?.host.isNotEmpty == true ? uri!.host
    : uri?.path.split('/').lastOrNull ?? 'Browser';
}
