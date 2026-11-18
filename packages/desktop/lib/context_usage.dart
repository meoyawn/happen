import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';

class ContextUsageIndicator extends StatelessWidget {
  const ContextUsageIndicator({super.key, required this.tokens, required this.onPressed, this.limit, this.estimatedTokens});
  final Json? tokens;
  final VoidCallback onPressed;
  final num? limit;
  final int? estimatedTokens;

  @override
  Widget build(BuildContext context) {
    final estimated = tokens == null && estimatedTokens != null;
    final used = tokens == null ? estimatedTokens : sessionTokenTotal(tokens!);
    final percent = used != null && limit != null && limit! > 0 ? (used / limit! * 100).clamp(0, 100).toDouble() : null;
    final prefix = estimated ? '~' : '';
    return Tooltip(message: percent == null ? 'View context usage' :
      '${estimated ? 'Estimated context usage' : 'Context usage'}: ${percent.round()}%', child: TextButton(
      key: const ValueKey('view-context'), onPressed: onPressed,
      style: TextButton.styleFrom(foregroundColor: desktopTertiary, padding: const EdgeInsets.symmetric(horizontal: 8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox.square(dimension: 16, child: CustomPaint(painter: _ContextUsagePainter(percent))),
        const SizedBox(width: 8),
        Text(percent != null ? '$prefix${percent.round()}%' : used == null ? 'Context' :
          used < 1000 ? '$prefix${used.round()}' : '$prefix${(used / 1000).toStringAsFixed(0)}k',
          style: const TextStyle(fontSize: 12)),
      ]),
    ));
  }
}

class _ContextUsagePainter extends CustomPainter {
  const _ContextUsagePainter(this.percent);
  final double? percent;

  @override
  void paint(Canvas canvas, Size size) {
    const ink = desktopForeground;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - 2) / 2;
    final paint = Paint()..style = PaintingStyle.stroke..strokeWidth = 2;
    final value = percent;
    canvas.drawCircle(center, radius, paint..color = ink.withValues(alpha: value == null ? .32 : .16));
    if (value != null && value > 0) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius), -math.pi / 2,
        math.pi * 2 * value / 100, false, paint..color = ink.withValues(alpha: .7)..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(_ContextUsagePainter oldDelegate) => oldDelegate.percent != percent;
}
