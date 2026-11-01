import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// One sidebar surface docks beside the content or peeks over it while closed.
class DesktopSidebarFrame extends StatefulWidget {
  const DesktopSidebarFrame({super.key, required this.open, required this.width,
    required this.sidebar, required this.resizer, required this.child, required this.onToggle,
    this.unread = false, this.collapsedInset = 18, this.resizerOffset = 0, this.resizing = false});
  final bool open, unread;
  final double width;
  final double collapsedInset;
  final double resizerOffset;
  final bool resizing;
  final Widget sidebar, resizer, child;
  final VoidCallback onToggle;

  @override
  State<DesktopSidebarFrame> createState() => _DesktopSidebarFrameState();
}

class _DesktopSidebarFrameState extends State<DesktopSidebarFrame> with TickerProviderStateMixin {
  late final _dock = AnimationController(vsync: this, value: widget.open ? 1 : 0);
  late final _preview = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
  final _sidebarFocus = FocusScopeNode();
  final _toggleFocus = FocusNode();
  Timer? _dwell, _grace;
  bool _overToggle = false;

  @override
  void didUpdateWidget(DesktopSidebarFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open == oldWidget.open) return;
    _dwell?.cancel();
    _grace?.cancel();
    if (!widget.open) {
      _preview.value = 0;
      if (_sidebarFocus.hasFocus) _toggleFocus.requestFocus();
    }
    // OpenCode scales its panel spring by the distance; hover peeks use 180ms.
    final duration = (300 * math.sqrt(widget.width / 480)).clamp(150, 300).round();
    _dock.animateTo(widget.open ? 1 : 0,
      duration: Duration(milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : duration),
      curve: Curves.easeOutCubic).whenCompleteOrCancel(() {
        if (mounted && widget.open) _preview.value = 0;
      });
  }

  void _peekAfter(int milliseconds) {
    _grace?.cancel();
    if (widget.open || _dock.value != 0 || _preview.value > 0 || _dwell?.isActive == true) return;
    _dwell = Timer(Duration(milliseconds: milliseconds), () {
      if (!mounted || widget.open || ModalRoute.of(context)?.isCurrent != true) return;
      _preview.animateTo(1, duration: Duration(milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 180),
        curve: Curves.easeOutCubic);
    });
  }

  void _hidePreview() {
    _dwell?.cancel();
    if (widget.open || _grace?.isActive == true || _preview.value == 0) return;
    _grace = Timer(const Duration(milliseconds: 100), () {
      if (!mounted || widget.open || _overToggle || ModalRoute.of(context)?.isCurrent != true) return;
      _preview.animateTo(0, duration: Duration(milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 180),
        curve: Curves.easeOutCubic);
    });
  }

  void _pointer(Offset position) {
    if (widget.open) return;
    if (_overToggle) { _peekAfter(500); return; }
    if (_preview.value > 0 && position.dx <= widget.width + 15) {
      _grace?.cancel();
      return;
    }
    if (position.dx <= 24 && position.dy >= 56) {
      _peekAfter(40);
    } else {
      _hidePreview();
    }
  }

  @override
  void dispose() {
    _dwell?.cancel();
    _grace?.cancel();
    _dock.dispose();
    _preview.dispose();
    _sidebarFocus.dispose();
    _toggleFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    onExit: (_) => _hidePreview(),
    child: Listener(
      onPointerHover: (event) => _pointer(event.localPosition),
      child: AnimatedBuilder(animation: Listenable.merge([_dock, _preview]), builder: (context, _) {
        final shown = math.max(_dock.value, _preview.value);
        final peeking = !widget.open && _preview.value > 0;
        return ClipRect(child: Stack(children: [
          Row(children: [SizedBox(width: widget.width * _dock.value), Expanded(child: widget.child)]),
          Positioned(left: -widget.width * (1 - shown), top: 0, bottom: 0, width: widget.width,
            child: Offstage(offstage: shown == 0, child: ExcludeSemantics(excluding: shown == 0,
              child: ExcludeFocus(excluding: shown == 0, child: IgnorePointer(ignoring: !widget.open && !peeking,
                child: FocusScope(node: _sidebarFocus, child: DecoratedBox(
                  decoration: BoxDecoration(color: const Color(0xfff9f9f9),
                    boxShadow: peeking ? const [BoxShadow(color: Color(0x22000000), blurRadius: 14, offset: Offset(4, 0))] : null),
                  child: Stack(clipBehavior: Clip.none, children: [
                    Positioned.fill(child: widget.sidebar),
                  ]),
                )),
              )),
            ))),
          // Keep both halves of the handle in the parent's hit-test bounds.
          Positioned(left: widget.width * _dock.value + widget.resizerOffset - 4, top: 0, bottom: 0,
            child: Offstage(offstage: !widget.open, child: widget.resizer)),
          Positioned(top: 18, left: widget.collapsedInset + (widget.width - 36 - widget.collapsedInset) * _dock.value,
            child: MouseRegion(
              onEnter: (_) { _overToggle = true; _peekAfter(500); },
              onExit: (_) { _overToggle = false; _dwell?.cancel(); },
              child: Semantics(expanded: widget.open, child: IconButton(
                key: const ValueKey('sidebar-toggle'), focusNode: _toggleFocus,
                tooltip: 'Toggle sidebar (${defaultTargetPlatform == TargetPlatform.macOS ? '⌘⇧B' : 'Ctrl+Shift+B'})',
                onPressed: widget.onToggle,
                style: IconButton.styleFrom(minimumSize: const Size(28, 28), maximumSize: const Size(28, 28),
                  padding: EdgeInsets.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                icon: Stack(clipBehavior: Clip.none, children: [
                  CustomPaint(size: const Size(16, 16), painter: _SidebarGlyph(widget.open)),
                  if (!widget.open && widget.unread)
                    Positioned(right: -2, bottom: -2, child: Container(width: 6, height: 6,
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xff5876db)))),
                ]),
              )),
            )),
          if (widget.resizing)
            const Positioned.fill(child: MouseRegion(cursor: SystemMouseCursors.resizeColumn,
              opaque: false, hitTestBehavior: HitTestBehavior.translucent)),
        ]));
      }),
    ),
  );
}

class _SidebarGlyph extends CustomPainter {
  const _SidebarGlyph(this.open);
  final bool open;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xff808080)..strokeWidth = 1.25..style = PaintingStyle.stroke;
    canvas.drawRect(const Rect.fromLTWH(2, 2.5, 12, 11), paint);
    canvas.drawLine(const Offset(6, 2.5), const Offset(6, 13.5), paint);
    if (open) canvas.drawRect(const Rect.fromLTWH(2.5, 3, 3, 10), Paint()..color = const Color(0xff808080));
  }

  @override
  bool shouldRepaint(_SidebarGlyph oldDelegate) => open != oldDelegate.open;
}
