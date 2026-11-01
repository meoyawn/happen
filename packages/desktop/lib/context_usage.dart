import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

class ContextUsageIndicator extends StatelessWidget {
  const ContextUsageIndicator({super.key, required this.messages, required this.onPressed, this.limit});
  final Iterable<Json> messages;
  final VoidCallback onPressed;
  final num? limit;

  @override
  Widget build(BuildContext context) {
    final message = lastAssistantWithUsage(messages);
    final used = message == null ? null : sessionTokenTotal(jsonObject(message['tokens']));
    final percent = used != null && limit != null && limit! > 0 ? (used / limit! * 100).clamp(0, 100).toDouble() : null;
    return Tooltip(message: 'View context usage', child: TextButton(
      key: const ValueKey('view-context'), onPressed: onPressed,
      style: TextButton.styleFrom(foregroundColor: const Color(0xff808080), padding: const EdgeInsets.symmetric(horizontal: 8)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox.square(dimension: 16, child: CustomPaint(painter: _ContextUsagePainter(percent))),
        const SizedBox(width: 8),
        Text(used == null ? 'Context' : used < 1000 ? '${used.round()}' : '${(used / 1000).toStringAsFixed(0)}k',
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
    const ink = Color(0xff1a1c1f);
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
