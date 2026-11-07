import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class SidebarActivityIndicator extends StatefulWidget {
  const SidebarActivityIndicator({super.key, required this.color});
  final Color color;

  @override
  State<SidebarActivityIndicator> createState() => _SidebarActivityIndicatorState();
}

class _SidebarActivityIndicatorState extends State<SidebarActivityIndicator> with SingleTickerProviderStateMixin {
  final _frame = ValueNotifier<int>(0);
  late final _rotation = AnimationController(vsync: this, duration: const Duration(seconds: 2))
    ..addListener(_advance);

  void _advance() {
    // Harness's 60 steps per turn: repaint at 30fps even on faster displays.
    _frame.value = (_rotation.value * 60).floor() % 60;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) || !TickerMode.valuesOf(context).enabled) {
      _rotation.stop();
    } else if (!_rotation.isAnimating) {
      _rotation.repeat();
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(child: RepaintBoundary(
    child: SizedBox.square(dimension: 14, child: CustomPaint(painter: _SidebarActivityPainter(widget.color, _frame))),
  ));
}

class _SidebarActivityPainter extends CustomPainter {
  _SidebarActivityPainter(this.color, this.frame) : super(repaint: frame);
  final Color color;
  final ValueListenable<int> frame;

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = (Offset.zero & size).deflate(1.5);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: color.a * .3);
    canvas.drawOval(bounds, paint);
    paint.color = color;
    canvas.drawArc(bounds, -math.pi / 2 + frame.value * math.pi / 30, math.pi * 1.5, false, paint);
  }

  @override
  bool shouldRepaint(_SidebarActivityPainter oldDelegate) => color != oldDelegate.color || frame != oldDelegate.frame;
}
