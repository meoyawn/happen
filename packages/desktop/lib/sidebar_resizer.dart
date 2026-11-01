import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// OpenCode ui/resize-handle: delayed pill, immediate drag, anchored sizing.
class SidebarResizer extends StatefulWidget {
  const SidebarResizer({super.key, required this.size, required this.min, required this.max,
    required this.onResize, required this.onResizeEnd, required this.onCancel, this.label = 'Resize sidebar'});
  final double size, min, max;
  final String label;
  final ValueChanged<double> onResize, onResizeEnd;
  final VoidCallback onCancel;

  @override
  State<SidebarResizer> createState() => _SidebarResizerState();
}

class _SidebarResizerState extends State<SidebarResizer> with SingleTickerProviderStateMixin {
  late final _opacity = AnimationController(vsync: this);
  Timer? _dwell;
  int? _pointer;
  double _start = 0, _startSize = 0, _size = 0;
  bool _hovered = false, _moved = false;

  void _fade(bool visible) {
    _opacity.animateTo(visible ? 1 : 0,
      duration: Duration(milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : visible ? 150 : 110),
      curve: visible ? const Cubic(.2, .8, .2, 1) : const Cubic(.4, 0, 1, 1));
  }

  void _hover(bool hovered) {
    _hovered = hovered;
    _dwell?.cancel();
    if (_pointer != null) return;
    if (hovered) {
      _dwell = Timer(const Duration(milliseconds: 200), () {
        if (mounted && _hovered) _fade(true);
      });
    } else {
      _fade(false);
    }
  }

  void _down(PointerDownEvent event) {
    if (_pointer != null || event.buttons & kPrimaryButton == 0) return;
    _dwell?.cancel();
    setState(() {
      _pointer = event.pointer;
      _start = event.position.dx;
      _startSize = _size = widget.size;
      _moved = false;
    });
    _fade(true);
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    final delta = event.position.dx - _start;
    if (!_moved && delta == 0) return;
    _moved = true;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    _size = (_startSize + (rtl ? -delta : delta)).clamp(widget.min, widget.max).toDouble();
    widget.onResize(_size);
  }

  void _end(int pointer, {bool cancelled = false}) {
    if (pointer != _pointer) return;
    if (_moved) {
      if (cancelled) {
        widget.onCancel();
      } else {
        widget.onResizeEnd(_size);
      }
    }
    setState(() => _pointer = null);
    _fade(_hovered);
  }

  @override
  void dispose() {
    _dwell?.cancel();
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(label: widget.label, child: MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    onEnter: (_) => _hover(true), onExit: (_) => _hover(false),
    child: Listener(behavior: HitTestBehavior.opaque,
      onPointerDown: _down, onPointerMove: _move,
      onPointerUp: (event) => _end(event.pointer),
      onPointerCancel: (event) => _end(event.pointer, cancelled: true),
      child: SizedBox(width: 8, height: double.infinity, child: Center(
        child: FadeTransition(opacity: _opacity, child: AnimatedContainer(
          width: 4, height: 40,
          duration: Duration(milliseconds: MediaQuery.disableAnimationsOf(context) ? 0 : 150),
          curve: const Cubic(.2, .8, .2, 1),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(9999),
            color: _pointer != null ? const Color(0xff3a3a3a) : const Color(0xff808080)),
        )),
      )),
    ),
  ));
}
