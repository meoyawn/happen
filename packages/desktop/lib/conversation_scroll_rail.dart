import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'appearance.dart';
import 'conversation_markdown.dart';

typedef ConversationPrompt = ({String id, String text, String? response, int index,
  ValueListenable<String>? liveResponse});

class ConversationScrollAnchor extends SingleChildRenderObjectWidget {
  const ConversationScrollAnchor({super.key, required this.id, required this.anchors, required super.child});
  final String id;
  final Map<String, RenderBox> anchors;
  @override
  RenderObject createRenderObject(BuildContext context) => _ScrollAnchorBox(id, anchors);
  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) => (renderObject as _ScrollAnchorBox).adopt(id, anchors);
}

class _ScrollAnchorBox extends RenderProxyBox {
  _ScrollAnchorBox(this.id, this.anchors);
  String id;
  Map<String, RenderBox> anchors;
  void _release() { if (identical(anchors[id], this)) anchors.remove(id); }
  void adopt(String nextId, Map<String, RenderBox> nextAnchors) {
    if (id == nextId && identical(anchors, nextAnchors)) return;
    _release(); id = nextId; anchors = nextAnchors;
    if (attached) anchors[id] = this;
  }
  @override
  void attach(PipelineOwner owner) { super.attach(owner); anchors[id] = this; }
  @override
  void detach() { _release(); super.detach(); }
}

/// Harness's prompt navigation rail. Only its own marks rebuild on scroll;
/// message bodies and their geometry remain owned by the lazy transcript.
class ConversationScrollRail extends StatefulWidget {
  const ConversationScrollRail({super.key, required this.entries, required this.visibleEntries,
    required this.maxHeight, required this.directory, required this.onReveal});
  final List<ConversationPrompt> entries;
  final Set<String> visibleEntries;
  final double maxHeight;
  final String directory;
  final void Function(String id, {bool instant}) onReveal;

  @override
  State<ConversationScrollRail> createState() => _ConversationScrollRailState();
}

class _ConversationScrollRailState extends State<ConversationScrollRail> {
  final _scroll = ScrollController();
  final _preview = OverlayPortalController();
  final _railKey = GlobalKey();
  int? _hovered, _focused, _scrubbed, _pointer;
  bool _moved = false, _inside = false, _scheduled = false;
  Timer? _previewDelay;
  double _previewY = 0;
  String? _previewId;
  Set<String> _lastVisible = const {};
  List<String> _entryIds = const [];

  @override
  void initState() { super.initState(); _scroll.addListener(_railScrolled); }

  void _railScrolled() {
    if (!mounted || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      if (_previewId != null && _scroll.hasClients) {
        final index = widget.entries.indexWhere((entry) => entry.id == _previewId);
        final box = _railKey.currentContext?.findRenderObject();
        if (index >= 0 && box is RenderBox && box.hasSize) {
          _previewY = box.localToGlobal(Offset(36, index * 10 - _scroll.offset + 5)).dy;
        }
      }
      setState(() {});
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _adoptEntries() {
    final next = widget.entries.map((entry) => entry.id).toList();
    if (listEquals(next, _entryIds)) return;
    int? remap(int? index) {
      if (index == null || index >= _entryIds.length) return null;
      final updated = next.indexOf(_entryIds[index]);
      return updated < 0 ? null : updated;
    }
    _hovered = remap(_hovered);
    _focused = remap(_focused);
    _scrubbed = remap(_scrubbed);
    _entryIds = next;
    _lastVisible = const {};
    if (_previewId != null && !next.contains(_previewId)) _hide();
  }

  void _select(int index, {bool delay = true}) {
    if (index < 0 || index >= widget.entries.length) return;
    _previewDelay?.cancel();
    final id = widget.entries[index].id;
    setState(() => _hovered = index);
    void show() {
      if (!mounted) return;
      final current = widget.entries.indexWhere((entry) => entry.id == id);
      if (current < 0 || !_inside && _focused != current) return;
      final box = _railKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !_scroll.hasClients) return;
      _previewY = box.localToGlobal(Offset(36, current * 10 - _scroll.offset + 5)).dy;
      _previewId = id;
      _preview.show();
    }
    if (delay) { _previewDelay = Timer(const Duration(milliseconds: 150), show); }
    else { show(); }
  }

  void _hide() {
    _previewDelay?.cancel();
    _previewId = null;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _previewId == null) _preview.hide(); });
    } else { _preview.hide(); }
  }

  int? _indexAt(Offset position) {
    if (widget.entries.isEmpty) return null;
    final box = _railKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !_scroll.hasClients) return null;
    final y = box.globalToLocal(position).dy.clamp(0.0, math.max(0.0, box.size.height - .01));
    return ((y + _scroll.offset) / 10).floor().clamp(0, widget.entries.length - 1);
  }

  void _finish(PointerEvent event) {
    if (event.pointer != _pointer) return;
    final index = _scrubbed;
    _pointer = null;
    setState(() => _scrubbed = null);
    if (!_moved && index != null && index < widget.entries.length) widget.onReveal(widget.entries[index].id);
    if (!_inside) { _hovered = null; _hide(); }
  }

  void _keepVisible() {
    final visible = widget.visibleEntries;
    if (setEquals(_lastVisible, visible)) return;
    _lastVisible = visible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scrubbed != null || !_scroll.hasClients) return;
      final index = widget.entries.indexWhere((entry) => visible.contains(entry.id));
      if (index < 0) return;
      final top = index * 10.0, bottom = top + 10;
      final position = _scroll.position;
      if (top < position.pixels) {
        _scroll.jumpTo(top.clamp(0, position.maxScrollExtent).toDouble());
      } else if (bottom > position.pixels + position.viewportDimension) {
        _scroll.jumpTo((bottom - position.viewportDimension + 1).clamp(0, position.maxScrollExtent).toDouble());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _adoptEntries();
    _keepVisible();
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final selected = _scrubbed ?? _hovered ?? _focused;
    return TweenAnimationBuilder<double>(tween: Tween(begin: 0, end: 1),
      duration: reducedMotion ? Duration.zero : const Duration(milliseconds: 150),
      builder: (context, opacity, child) => Opacity(opacity: opacity, child: child),
      child: OverlayPortal(controller: _preview, overlayChildBuilder: (context) {
        final box = _railKey.currentContext?.findRenderObject();
        final overlay = Overlay.of(context).context.findRenderObject();
        final entry = widget.entries.where((entry) => entry.id == _previewId).firstOrNull;
        if (box is! RenderBox || overlay is! RenderBox || entry == null) return const SizedBox.shrink();
        final start = overlay.globalToLocal(box.localToGlobal(const Offset(36, 0)));
        final center = overlay.globalToLocal(Offset(0, _previewY)).dy;
        final width = math.min(320.0, math.max(0.0, overlay.size.width - start.dx - 8));
        return Positioned(left: start.dx, top: math.max(8.0, math.min(overlay.size.height - 124, center - 50)), width: width,
          child: IgnorePointer(child: _PromptPreview(entry: entry, directory: widget.directory)));
      }, child: MouseRegion(onEnter: (_) => _inside = true, onExit: (_) {
        _inside = false;
        if (_scrubbed == null) { setState(() => _hovered = null); _hide(); }
      }, child: Listener(
        onPointerDown: (event) {
          if (event.buttons != kPrimaryButton) return;
          final index = _indexAt(event.position);
          if (index == null) return;
          _pointer = event.pointer;
          _moved = false;
          setState(() => _scrubbed = index);
          _select(index, delay: false);
        },
        onPointerMove: (event) {
          if (event.pointer != _pointer) return;
          final index = _indexAt(event.position);
          if (index == null || index == _scrubbed) return;
          _moved = true;
          setState(() => _scrubbed = index);
          _select(index, delay: false);
          widget.onReveal(widget.entries[index].id, instant: true);
        }, onPointerUp: _finish, onPointerCancel: (event) {
          if (event.pointer == _pointer) { _pointer = null; setState(() => _scrubbed = null); _hide(); }
        }, child: SizedBox(key: _railKey, width: 36, height: math.min(widget.entries.length * 10.0, widget.maxHeight),
          child: ShaderMask(blendMode: BlendMode.dstIn, shaderCallback: (bounds) {
            final extent = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
            final progress = extent > 0 ? ((_scroll.offset / extent - .01) / .98).clamp(0.0, 1.0) : 0.0;
            final top = extent > 0 ? math.min(40 * progress / bounds.height, .5) : 0.0;
            final bottom = extent > 0 ? math.min(40 * (1 - progress) / bounds.height, .5) : 0.0;
            return LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [top > 0 ? Colors.transparent : Colors.white, Colors.white, Colors.white, bottom > 0 ? Colors.transparent : Colors.white],
              stops: [0, top, 1 - bottom, 1]).createShader(bounds);
          }, child: ScrollConfiguration(behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false), child: ListView.builder(
            controller: _scroll, padding: EdgeInsets.zero, itemExtent: 10, itemCount: widget.entries.length,
            findChildIndexCallback: (key) {
              if (key is! ValueKey<String>) return null;
              final index = widget.entries.indexWhere((entry) => entry.id == key.value);
              return index < 0 ? null : index;
            }, itemBuilder: (context, index) {
              final entry = widget.entries[index];
              final distance = selected == null ? null : (index - selected).abs();
              final progress = switch (distance) {0 => 1.0, 1 => .7, 2 => .4, 3 => .2, _ => 0.0};
              final active = widget.visibleEntries.contains(entry.id);
              final opacity = distance == 0 ? 1.0 : active && selected == null ? .6 : .4;
              final color = distance == 0 || active && selected == null ? desktopForeground : desktopSecondary;
              return Semantics(key: ValueKey(entry.id), button: true, label: 'Jump to user message ${index + 1}', selected: active,
                onTap: () => widget.onReveal(entry.id), child: FocusableActionDetector(mouseCursor: SystemMouseCursors.click,
                  onShowFocusHighlight: (value) {
                    setState(() { _focused = value ? index : null; if (!value && !_inside) _hovered = null; });
                    if (value) { _select(index); } else if (!_inside) { _hide(); }
                  },
                  onShowHoverHighlight: (value) { if (value && _scrubbed == null) _select(index); },
                  actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) { widget.onReveal(entry.id); return null; })},
                  child: Align(alignment: Alignment.centerLeft, child: AnimatedContainer(
                    duration: _scrubbed != null || reducedMotion ? Duration.zero : const Duration(milliseconds: 160),
                    curve: const _MarkerCurve(), width: 6 + 20 * progress, height: 2,
                    color: color.withValues(alpha: color.a * opacity))),
                ));
            },
          )))),
      ))),
    );
  }

  @override
  void deactivate() { _previewDelay?.cancel(); super.deactivate(); }

  @override
  void dispose() { _previewDelay?.cancel(); _scroll.removeListener(_railScrolled); _scroll.dispose(); super.dispose(); }
}

class _MarkerCurve extends Curve {
  const _MarkerCurve();
  static const _points = [(0.0, 0.0), (.1, .398), (.2, .682), (.3, .843), (.4, .925),
    (.5, .972), (.6, 1.004), (.7, 1.008), (.8, 1.003), (1.0, 1.0)];
  @override
  double transformInternal(double t) {
    for (var index = 1; index < _points.length; index++) {
      final (end, value) = _points[index];
      if (t <= end) {
        final (start, previous) = _points[index - 1];
        return previous + (value - previous) * (t - start) / (end - start);
      }
    }
    return 1;
  }
}

class _PromptPreview extends StatelessWidget {
  const _PromptPreview({required this.entry, required this.directory});
  final ConversationPrompt entry;
  final String directory;

  Widget _response(String? text) => text == null || text.isEmpty ? const SizedBox.shrink()
    : Padding(padding: const EdgeInsets.only(top: 4), child: ClipRect(
      child: ConstrainedBox(constraints: const BoxConstraints(maxHeight: 60),
        child: SingleChildScrollView(primary: false, physics: const NeverScrollableScrollPhysics(),
          child: ConversationMarkdown(text: text, directory: directory, fontSize: 13, reasoning: true)))));

  @override
  Widget build(BuildContext context) => Material(color: Colors.transparent, child: SelectionContainer.disabled(child: Container(
    padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: desktopSidebar,
      borderRadius: BorderRadius.circular(12), border: Border.all(color: desktopBorderStrong, width: .5),
      boxShadow: const [BoxShadow(color: Color(0x291a1c1f), blurRadius: 24, offset: Offset(0, 8))]),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(entry.text, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, height: 20 / 13, color: desktopForeground)),
      if (entry.liveResponse case final source?) ValueListenableBuilder<String>(valueListenable: source,
        builder: (context, text, _) => _response(text.isEmpty ? entry.response : text))
      else _response(entry.response),
    ]),
  )));
}
