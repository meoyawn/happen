import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
    if (icon == MachineIcon.ubuntu) {
      return SvgPicture.asset('assets/machine-icons/ubuntu.svg',
        width: size, height: size, semanticsLabel: machineIconLabel(icon));
    }
    if (icon == MachineIcon.apple) {
      return SvgPicture.asset('assets/machine-icons/apple.svg',
        width: size, height: size, semanticsLabel: machineIconLabel(icon));
    }
    final glyph = switch (icon) {
      MachineIcon.laptop => Icons.laptop_mac_outlined,
      MachineIcon.desktop => Icons.desktop_mac_outlined,
      MachineIcon.server => Icons.dns_outlined,
      _ => null,
    };
    if (glyph != null) return Icon(glyph, size: size, color: color, semanticLabel: machineIconLabel(icon));
    return Semantics(label: machineIconLabel(icon), child: SizedBox.square(dimension: size,
      child: CustomPaint(painter: _LinuxLogo(color ?? IconTheme.of(context).color ?? Colors.black))));
  }
}

class _LinuxLogo extends CustomPainter {
  const _LinuxLogo(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()..color = color;
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
    canvas.restore();
  }

  @override
  bool shouldRepaint(_LinuxLogo oldDelegate) => oldDelegate.color != color;
}
