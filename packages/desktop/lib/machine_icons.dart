import 'dart:math' as math;

import 'package:flutter/material.dart';

enum MachineIcon { laptop, desktop, apple, server, linux, ubuntu }

String machineIconLabel(MachineIcon icon) => switch (icon) {
  MachineIcon.laptop => 'Laptop', MachineIcon.desktop => 'Desktop',
  MachineIcon.apple => 'Apple',
  MachineIcon.server => 'Server / VPS', MachineIcon.linux => 'Linux', MachineIcon.ubuntu => 'Ubuntu',
};

MachineIcon parseMachineIcon(String? value, {required bool remote}) =>
  MachineIcon.values.where((icon) => icon.name == value).firstOrNull ?? (remote ? MachineIcon.server : MachineIcon.laptop);

class MachineGlyph extends StatelessWidget {
  const MachineGlyph(this.icon, {super.key, this.size = 14, this.color});
  final MachineIcon icon;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final glyph = switch (icon) {
      MachineIcon.laptop => Icons.laptop_mac_outlined,
      MachineIcon.desktop => Icons.desktop_mac_outlined,
      MachineIcon.server => Icons.dns_outlined,
      _ => null,
    };
    if (glyph != null) return Icon(glyph, size: size, color: color, semanticLabel: machineIconLabel(icon));
    return Semantics(label: machineIconLabel(icon), child: SizedBox.square(dimension: size,
      child: CustomPaint(painter: _MachineLogo(icon, color ?? IconTheme.of(context).color ?? Colors.black))));
  }
}

class _MachineLogo extends CustomPainter {
  const _MachineLogo(this.icon, this.color);
  final MachineIcon icon;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()..color = color;
    if (icon == MachineIcon.ubuntu) {
      paint..style = PaintingStyle.stroke..strokeWidth = 2.7..strokeCap = StrokeCap.butt;
      for (var index = 0; index < 3; index++) {
        final angle = index * math.pi * 2 / 3 - math.pi / 2;
        canvas.drawArc(const Rect.fromLTWH(5, 5, 14, 14), angle + .27, math.pi * 2 / 3 - .54, false, paint);
      }
      paint.style = PaintingStyle.fill;
      for (var index = 0; index < 3; index++) {
        final angle = index * math.pi * 2 / 3 - math.pi / 2;
        canvas.drawCircle(Offset(12 + math.cos(angle) * 9, 12 + math.sin(angle) * 9), 2.1, paint);
      }
    } else if (icon == MachineIcon.apple) {
      canvas.drawPath(Path()..moveTo(15, 5)..cubicTo(14.8, 2.7, 16.2, .7, 18.3, .3)
        ..cubicTo(18.6, 2.5, 17.1, 4.7, 15, 5)..close(), paint);
      canvas.drawPath(Path()..moveTo(12, 6)..cubicTo(9.3, 4.3, 5, 5.1, 3.8, 9)
        ..cubicTo(2, 14.8, 7, 23, 9.8, 23)..cubicTo(11, 23, 11.5, 22.1, 13, 22.1)
        ..cubicTo(14.5, 22.1, 15, 23, 16.3, 23)..cubicTo(18.5, 23, 20.8, 19.1, 21.6, 16.7)
        ..cubicTo(17, 14.7, 17.1, 10, 21, 8.2)..cubicTo(18.5, 4, 15.7, 4.4, 12, 6)..close(), paint);
    } else {
      canvas.drawOval(const Rect.fromLTWH(5, 7, 14, 15), paint);
      canvas.drawOval(const Rect.fromLTWH(7, 1, 10, 14), paint);
      canvas.drawPath(Path()..moveTo(6, 10)..quadraticBezierTo(1, 15, 3, 18)
        ..lineTo(8, 14)..close(), paint);
      canvas.drawPath(Path()..moveTo(18, 10)..quadraticBezierTo(23, 15, 21, 18)
        ..lineTo(16, 14)..close(), paint);
      canvas.drawOval(const Rect.fromLTWH(8, 10, 8, 10), Paint()..color = Colors.white);
      for (final x in [9.5, 14.5]) {
        canvas.drawOval(Rect.fromCenter(center: Offset(x, 6), width: 3.5, height: 4.5), Paint()..color = Colors.white);
        canvas.drawCircle(Offset(x, 6.5), .8, paint);
      }
      canvas.drawPath(Path()..moveTo(9, 8)..lineTo(15, 8)..lineTo(12, 10.5)..close(), paint);
      canvas.drawOval(const Rect.fromLTWH(3, 20, 8, 3), paint);
      canvas.drawOval(const Rect.fromLTWH(13, 20, 8, 3), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MachineLogo oldDelegate) => oldDelegate.icon != icon || oldDelegate.color != color;
}
