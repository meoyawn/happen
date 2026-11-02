import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'session.dart';

// OpenCode: ui/src/data-display/project-avatar/{project-avatar.tsx,project-avatar.css}.
class ProjectAvatar extends StatelessWidget {
  const ProjectAvatar({super.key, required this.project, this.size = 16, this.generated = false});
  final Project project;
  final double size;
  final bool generated;

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: size, child: generated
    ? RepaintBoundary(child: CustomPaint(painter: _AvatarPainter(project.id)))
    : DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: [Color(0xff767676), Color(0xff5c5c5c)]),
          border: Border.all(color: const Color(0xff3a3a3a), width: .5)),
        child: Center(child: Text(project.name.characters.firstOrNull?.toUpperCase() ?? '',
          style: TextStyle(fontSize: size * 11 / 16, height: 1, fontWeight: FontWeight.w500,
            letterSpacing: .05, color: Colors.white,
            shadows: const [Shadow(color: Color(0x33000000), blurRadius: 4)]))),
      ));
}

// OpenCode's optional mesh generator (generated.ts, version 1).
final _pictures = <String, ui.Picture>{};
final _float = Float32List(1);
double _f(double value) { _float[0] = value; return _float[0]; }
double _fract(double value) => _f(value - value.floorToDouble());
double _clamp(double value) => value.clamp(0.0, 1.0);
double _smooth(double from, double to, double value) {
  final t = _clamp((value - from) / (to - from));
  return t * t * (3 - 2 * t);
}

double _hash(double x, double y) {
  var px = _fract(_f(x * _f(123.34))), py = _fract(_f(y * _f(456.21)));
  final d = _f(_f(px * _f(px + _f(45.32))) + _f(py * _f(py + _f(45.32))));
  px = _f(px + d);
  py = _f(py + d);
  return _fract(_f(px * py));
}

double _noise(double x, double y) {
  final ix = x.floorToDouble(), iy = y.floorToDouble(), fx = x - ix, fy = y - iy;
  final sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy);
  final a = _hash(ix, iy), b = _hash(ix + 1, iy), c = _hash(ix, iy + 1), d = _hash(ix + 1, iy + 1);
  return a + (b - a) * sx + (c - a + (d - c - b + a) * sx) * sy;
}

int _seed(String input) {
  var h1 = 0xdeadbeef, h2 = 0x41c6ce57;
  for (final ch in input.codeUnits) {
    h1 = ((h1 ^ ch) * 2654435761) & 0xffffffff;
    h2 = ((h2 ^ ch) * 1597334677) & 0xffffffff;
  }
  h1 = (((h1 ^ (h1 >>> 16)) * 2246822507) ^ ((h2 ^ (h2 >>> 13)) * 3266489909)) & 0xffffffff;
  h2 = (((h2 ^ (h2 >>> 16)) * 2246822507) ^ ((h1 ^ (h1 >>> 13)) * 3266489909)) & 0xffffffff;
  return (h1 ^ h2) & 0xffffffff;
}

double Function() _random(String key, String tag) {
  var a = _seed('$key|0|$tag');
  return () {
    a = (a + 0x6d2b79f5) & 0xffffffff;
    var t = ((a ^ (a >>> 15)) * (1 | a)) & 0xffffffff;
    t = (((t + (((t ^ (t >>> 7)) * (61 | t)) & 0xffffffff)) & 0xffffffff) ^ t) & 0xffffffff;
    return ((t ^ (t >>> 14)) & 0xffffffff) / 4294967296;
  };
}

const _palettes = [
  [0x1d3557, 0xe63946, 0xf1a208, 0x2a9d8f],
  [0x264653, 0xe76f51, 0xf4a261, 0xe9c46a],
  [0x3d405b, 0xe07a5f, 0x81b29a, 0xf2cc8f],
  [0x0b3954, 0x087e8b, 0xff5a5f, 0xc81d25],
  [0x5f0f40, 0x9a031e, 0xfb8b24, 0x0f4c5c],
  [0x10451d, 0x4c956c, 0xd68c45, 0xf2e8cf],
  [0x22223b, 0x4a4e69, 0x9a8c98, 0xc9ada7],
  [0x3a0ca3, 0xff006e, 0x3a86ff, 0xffbe0b],
  [0x003049, 0xd62828, 0xf77f00, 0xfcbf49],
  [0x335c67, 0xe09f3e, 0x9e2a2b, 0x540b0e],
  [0x2d3047, 0x419d78, 0xe0a458, 0xffdbb5],
  [0x283618, 0x606c38, 0xdda15e, 0xbc6c25],
];

ui.Picture _draw(String key) {
  const px = 48;
  final palette = _palettes[(_random(key, 'palette')() * _palettes.length).floor()];
  final colors = [for (final value in palette) [((value >> 16) & 255) / 255, ((value >> 8) & 255) / 255, (value & 255) / 255]];
  final mesh = _random(key, 'mesh'), post = _random(key, 'post');
  final seedX = mesh() * 40, seedY = mesh() * 40, grainX = (post() * 64).floor(), grainY = (post() * 64).floor();
  double height(double x, double y) {
    final sx = x * .45, sy = y * .45;
    return (.7 * _noise(sx, sy) + .3 * _noise(sx * 2.3 + 3, sy * 2.3 + 3)) * .4;
  }
  final recorder = ui.PictureRecorder(), paint = Paint()..isAntiAlias = false;
  final canvas = Canvas(recorder);
  final length = math.sqrt(.16 + .36 + .49);
  for (var row = 0; row < px; row++) {
    for (var column = 0; column < px; column++) {
      final u = (column + .5) / px, v = (px - row - .5) / px;
      final dx = (u * 2 - 1).abs() - .56, dy = (v * 2 - 1).abs() - .56;
      final distance = math.sqrt(math.pow(math.max(dx, 0), 2) + math.pow(math.max(dy, 0), 2)) + math.min(math.max(dx, dy), 0) - .44;
      final mask = 1 - _smooth(-3 / px, 1 / px, distance);
      if (mask <= 0) continue;
      final x = u * 1.6 * .95 * 1.6 + seedX, y = (v - u * .02) * .95 * 1.6 + seedY;
      var r = colors[0][0], g = colors[0][1], b = colors[0][2];
      for (var i = 0; i < 3; i++) {
        final sx = x * (.35 + .12 * i), sy = y * .6 + i * 3.7;
        final n = .65 * _noise(sx, sy) + .35 * _noise(sx * 2.1 + 7, sy * 2.1 + 7);
        final k = _smooth(.35, .75, n), c = colors[i + 1];
        r += (c[0] - r) * k;
        g += (c[1] - g) * k;
        b += (c[2] - b) * k;
      }
      final h = height(x, y), nx = -(height(x + .02, y) - h) / .02, ny = -(height(x, y + .02) - h) / .02;
      final normal = math.sqrt(nx * nx + ny * ny + 1.4 * 1.4);
      final lit = (nx * -.4 + ny * .6 + 1.4 * .7) / normal / length;
      final shade = .78 + .38 * lit, gloss = math.pow(math.max(lit, 0), 18) * .25;
      final noise = math.sin(((column * 16 ~/ px) + grainX) * 127.1 + ((row * 16 ~/ px) + grainY) * 311.7) * 43758.5453;
      final grain = (noise - noise.floor() - .5) * 255 * .14;
      int channel(double value) => (_clamp(value * shade + gloss) * 255 + grain).round().clamp(0, 255);
      paint.color = Color.fromARGB((mask * 255).round(), channel(r), channel(g), channel(b));
      canvas.drawRect(Rect.fromLTWH(column.toDouble(), row.toDouble(), 1, 1), paint);
    }
  }
  return recorder.endRecording();
}

class _AvatarPainter extends CustomPainter {
  _AvatarPainter(this.seed);
  final String seed;
  @override
  void paint(Canvas canvas, Size size) {
    final picture = _pictures.putIfAbsent(seed, () => _draw(seed));
    canvas.save();
    canvas.scale(size.width / 48, size.height / 48);
    canvas.drawPicture(picture);
    canvas.restore();
  }
  @override
  bool shouldRepaint(_AvatarPainter oldDelegate) => oldDelegate.seed != seed;
}
