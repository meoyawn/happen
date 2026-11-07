import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'appearance.dart';

/// Harness's two radial dot fields, repainted at 30fps without rebuilding rows.
class GeneratedImageLoading extends StatefulWidget {
  const GeneratedImageLoading({super.key, this.animate = true, this.thumbnail = false});
  final bool animate, thumbnail;
  @override
  State<GeneratedImageLoading> createState() => _GeneratedImageLoadingState();
}

class _GeneratedImageLoadingState extends State<GeneratedImageLoading>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _elapsed = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker(_tick);
  _DotFields? _fields;
  bool _reduced = false;
  double _last = -34;

  void _tick(Duration elapsed) {
    final ms = elapsed.inMicroseconds / 1000;
    if (ms - _last < 1000 / 30) return;
    _last = ms;
    _elapsed.value = ms;
  }

  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _synchronize();
  @override
  void didChangeDependencies() { super.didChangeDependencies(); _synchronize(); }
  @override
  void didUpdateWidget(GeneratedImageLoading oldWidget) { super.didUpdateWidget(oldWidget); _synchronize(); }

  void _synchronize() {
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (_fields == null || reduced != _reduced) _fields = _DotFields(reduced);
    _reduced = reduced;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final visible = lifecycle == null || lifecycle == AppLifecycleState.resumed || lifecycle == AppLifecycleState.inactive;
    if (widget.animate && !_reduced && visible && TickerMode.valuesOf(context).enabled) {
      if (!_ticker.isActive) { _last = -34; _ticker.start(); }
    } else { _ticker.stop(); }
  }

  @override
  void deactivate() {
    _ticker.stop();
    WidgetsBinding.instance.removeObserver(this);
    super.deactivate();
  }
  @override
  void activate() {
    super.activate();
    WidgetsBinding.instance.addObserver(this);
    _synchronize();
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _elapsed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(label: 'Generating image...', liveRegion: true,
    child: RepaintBoundary(child: ClipRRect(borderRadius: BorderRadius.circular(widget.thumbnail ? 8 : 16),
      child: ColoredBox(color: desktopMuted, child: CustomPaint(size: Size.infinite,
        painter: _GeneratedImageDots(_elapsed, _fields!, MediaQuery.devicePixelRatioOf(context), widget.thumbnail))))));
}

class _DotFields {
  _DotFields(bool reduced) {
    final random = math.Random();
    double between(double a, double b) => a + (reduced ? .5 : random.nextDouble()) * (b - a);
    durations = [for (final ms in [4500, 6330, 5600, 5750, 3600, 2400]) ms * 1.2 * between(1, 1.35)];
    phases = [for (var i = 0; i < 6; i++) between(0, 1)];
    bounds = [between(.1, .32), between(.68, .9), between(.1, .32), between(.68, .9),
      between(.68, .9), between(.1, .32), between(.68, .9), between(.1, .32)];
    sizes = [between(.42, .52), between(.62, .75), between(.5, .62), between(.74, .9)];
  }
  late final List<double> durations, phases, bounds, sizes;
}

class _GeneratedImageDots extends CustomPainter {
  _GeneratedImageDots(this.time, this.fields, this.dpr, this.thumbnail) : super(repaint: time);
  final ValueNotifier<double> time;
  final _DotFields fields;
  final double dpr;
  final bool thumbnail;
  static double smooth(double x) { final t = x.clamp(0.0, 1.0); return t * t * (3 - 2 * t); }
  static double cubic(double x) => x < .5 ? 4 * x * x * x : 1 - math.pow(-2 * x + 2, 3) / 2;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final ms = time.value;
    double phase(int i) { final t = (ms / fields.durations[i] + fields.phases[i]) % 1; return t <= .5 ? t * 2 : 2 - t * 2; }
    double mix(double a, double b, double t) => a + (b - a) * t;
    final b = fields.bounds, f = fields.sizes;
    final x1 = mix(b[0], b[1], cubic(phase(0))), y1 = mix(b[2], b[3], smooth(phase(1)));
    final x2 = mix(b[4], b[5], cubic(phase(2))), y2 = mix(b[6], b[7], smooth(phase(3)));
    final s1 = .78 * mix(f[0], f[1], smooth(phase(4))), s2 = .78 * mix(f[2], f[3], smooth(phase(5)));
    final spacing = thumbnail ? 6.0 : math.max(1.0, 12 / dpr);
    final nx = math.max(1, (size.width / spacing).floor()), ny = math.max(1, (size.height / spacing).floor());
    final left = (size.width - (nx - 1) * spacing) / 2, top = (size.height - (ny - 1) * spacing) / 2;
    final radius = thumbnail ? .75 : math.max(.55, spacing * .5 * .16);
    final t = (ms % 1750) / 1750;
    final pulse = .38 + .18 * Curves.easeInOut.transform(t <= .5 ? 2 * t : 2 - 2 * t);
    final paint = Paint();
    for (var y = 0; y < ny; y++) {
      final v = ny == 1 ? .5 : y / (ny - 1);
      for (var x = 0; x < nx; x++) {
        final u = nx == 1 ? .5 : x / (nx - 1);
        final a = ((1 - smooth(math.sqrt(math.pow(u - x1, 2) + math.pow(v - y1, 2)) / s1)) * 1.2 +
          (1 - smooth(math.sqrt(math.pow(u - x2, 2) + math.pow(v - y2, 2)) / s2)) * .82).clamp(0.0, 1.0);
        final alpha = math.pow(a, 1.18).toDouble();
        if (alpha <= .03) continue;
        final diagonal = (u + v) / 2;
        final mask = diagonal < .3 ? diagonal / .3 : diagonal > .7 ? (1 - diagonal) / .3 : 1.0;
        paint.color = desktopSecondary.withValues(alpha: alpha * pulse * mask.clamp(0.0, 1.0));
        canvas.drawCircle(Offset(left + x * spacing, top + y * spacing), radius, paint);
      }
    }
  }
  @override
  bool shouldRepaint(_GeneratedImageDots old) => old.fields != fields || old.dpr != dpr || old.thumbnail != thumbnail;
}
