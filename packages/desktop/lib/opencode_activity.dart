import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'appearance.dart';

// Port of OpenCode's ui/src/components/spinner-radar.ts: square rings,
// clockwise head, sampled trail, 1.8s loop, and the reduced-motion pose.
double _round(double value) => (value * 1000).round() / 1000;
double _fraction(double value) => value - value.floor();
final _clock = Stopwatch()..start();
final _trail = <(double, double)>[
  for (final (index, level) in [1.0, .987, .934, .812, .599, .384, .238, .143, .081, .041, .017, .004, 0.0].indexed)
    (index * 4.0, _round(.55 * level)),
  (100, 0),
];

double _level(List<(double, double)> stops, double percent) {
  final next = stops.indexWhere((stop) => stop.$1 >= percent);
  if (next <= 0) return stops.first.$2;
  final (p0, l0) = stops[next - 1];
  final (p1, l1) = stops[next];
  return l0 + (l1 - l0) * (percent - p0) / (p1 - p0 == 0 ? 1 : p1 - p0);
}

final _dots = [for (var y = -2; y <= 2; y++) for (var x = -2; x <= 2; x++)
  (x: x, y: y, at: _fraction(math.atan2(x.toDouble(), -y.toDouble()) / (2 * math.pi)))];
final _shapes = [for (final dot in _dots) () {
  if (dot.x == 0 && dot.y == 0) return <(double, double)>[(0, .55), (100, .55)];
  final others = _dots.where((other) => other != dot &&
    math.max(other.x.abs(), other.y.abs()) == math.max(dot.x.abs(), dot.y.abs()));
  final behind = _round(others.map((other) => _fraction(dot.at - other.at)).reduce(math.min)) * 100;
  final ahead = _round(others.map((other) => _fraction(other.at - dot.at)).reduce(math.min)) * 100;
  final off = ahead / 2 + 1.5, on = 100 - behind / 2;
  return <(double, double)>[(0, 1), (ahead / 2, 1), (off, _level(_trail, off)),
    ..._trail.where((stop) => stop.$1 > off && stop.$1 < 100 && stop.$1 < on - 1.5),
    (on - 1.5, 0), (on, 1), (100, 1)];
}()];

class OpenCodeActivityIndicator extends StatefulWidget {
  const OpenCodeActivityIndicator({super.key});

  @override
  State<OpenCodeActivityIndicator> createState() => _OpenCodeActivityIndicatorState();
}

class _OpenCodeActivityIndicatorState extends State<OpenCodeActivityIndicator> with SingleTickerProviderStateMixin {
  late final _animation = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (TickerMode.valuesOf(context).enabled && !MediaQuery.disableAnimationsOf(context)) {
      if (!_animation.isAnimating) _animation.repeat();
    } else {
      _animation.stop();
    }
  }

  @override
  void dispose() { _animation.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => RepaintBoundary(child: SizedBox.square(dimension: 16,
    child: CustomPaint(painter: _RadarPainter(_animation, MediaQuery.disableAnimationsOf(context)))));
}

class _RadarPainter extends CustomPainter {
  _RadarPainter(this.animation, this.still) : super(repaint: animation);
  final Animation<double> animation;
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    final phase = still ? .22 : (_clock.elapsedMicroseconds % 1800000) / 1800000;
    final paint = Paint();
    canvas.save();
    canvas.scale(size.width / 16, size.height / 16);
    for (var i = 0; i < _dots.length; i++) {
      final dot = _dots[i];
      final level = _level(_shapes[i], _fraction(phase - _round(dot.at)) * 100);
      paint.color = opencodeMuted.withValues(alpha: _round(.2 + .8 * level));
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(7 + dot.x * 3, 7 + dot.y * 3, 2, 2),
        const Radius.circular(.48)), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RadarPainter oldDelegate) => oldDelegate.still != still || oldDelegate.animation != animation;
}
