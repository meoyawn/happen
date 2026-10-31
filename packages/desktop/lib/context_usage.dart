import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

typedef _CacheTokens = ({num input, num cached});
typedef _ContextUsage = ({num? used, num? window, _CacheTokens? last, _CacheTokens? total});

num? _tokens(Object? value) => value is num && value.isFinite && value >= 0 ? value : null;

_CacheTokens? _cacheTokens(Object? value) {
  if (value is! Map) return null;
  final input = _tokens(value['input_tokens']), cached = _tokens(value['cached_input_tokens']);
  if (input == null || input == 0 || cached == null || cached > input) return null;
  return (input: input, cached: cached);
}

_ContextUsage _contextUsage(Iterable<Json> events) {
  final ordered = events.where((event) => const {
    'task.created', 'task.configuration_migrated', 'model.completed', 'context.compacted',
  }.contains(event['type'])).toList()
    ..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
  num? window, used;
  num totalInput = 0, totalCached = 0;
  _CacheTokens? last;
  for (final event in ordered) {
    final data = event['data'];
    if (data is! Map) continue;
    if (event['type'] == 'task.created' || event['type'] == 'task.configuration_migrated') {
      final settings = data['provider_settings'];
      window = settings is Map ? _tokens(settings['context_limit']) : null;
      continue;
    }
    final usage = data['usage'];
    final cache = _cacheTokens(usage);
    if (cache != null) {
      totalInput += cache.input;
      totalCached += cache.cached;
    }
    used = null;
    if (event['type'] == 'model.completed') {
      final input = usage is Map ? _tokens(usage['input_tokens']) : null;
      final output = usage is Map ? _tokens(usage['output_tokens']) : null;
      if (input != null && output != null) used = input + output;
      last = cache;
    }
    // A compaction request counts toward cache totals, but its input describes
    // the old context. Wait for a response that measures the replacement.
  }
  if (window == 0) window = null;
  if (used != null && !used.isFinite) used = null;
  return (used: used != null && window != null ? math.min(used, window) : used, window: window, last: last,
    total: totalInput > 0 && totalInput.isFinite && totalCached.isFinite
      ? (input: totalInput, cached: totalCached) : null);
}

String _cacheLine(String label, _CacheTokens counts) =>
  '$label: ${(counts.cached / counts.input * 100).toStringAsFixed(1)}% (${counts.cached.round()} / ${counts.input.round()} input tokens)';

class ContextUsageIndicator extends StatelessWidget {
  const ContextUsageIndicator({super.key, required this.events});
  final Iterable<Json> events;

  @override
  Widget build(BuildContext context) {
    final usage = _contextUsage(events);
    final used = usage.used, window = usage.window;
    final percent = used != null && window != null ? (used / window * 100).clamp(0.0, 100.0).toDouble() : null;
    final rounded = percent?.round();
    final status = rounded == null ? 'Usage unavailable' : rounded >= 50 ? '$rounded% full' : '$rounded% used (${100 - rounded}% left)';
    const muted = TextStyle(color: Color(0x99ffffff));
    final tooltip = TextSpan(style: const TextStyle(fontSize: 13, height: 18 / 13, color: Colors.white), children: [
      const TextSpan(text: 'Context window:\n', style: muted),
      TextSpan(text: status, style: rounded == null || rounded >= 50 ? muted : null),
      if (used != null && window != null)
        TextSpan(text: '\n${(used / 1000).round()}k / ${(window / 1000).round()}k tokens used')
      else if (used != null)
        TextSpan(text: '\n${(used / 1000).round()}k tokens used')
      else if (window != null)
        TextSpan(text: '\n${(window / 1000).round()}k token limit'),
      if (usage.total != null || usage.last != null) ...[
        const TextSpan(text: '\n\nCache hits\n', style: muted),
        if (usage.total case final counts?) TextSpan(text: _cacheLine('Conversation', counts)),
        if (usage.last case final counts?) TextSpan(text: '${usage.total == null ? '' : '\n'}${_cacheLine('Latest response', counts)}'),
      ],
    ]);
    return Padding(padding: const EdgeInsets.only(right: 5), child: Tooltip(
      richMessage: tooltip, excludeFromSemantics: true, preferBelow: false, verticalOffset: 4, textAlign: TextAlign.center,
      triggerMode: TooltipTriggerMode.tap, mouseCursor: SystemMouseCursors.help,
      child: SizedBox.square(dimension: 28, child: Center(child: Semantics(
        label: rounded == null ? 'Context usage: unavailable' : 'Context usage: $rounded%', image: true, excludeSemantics: true,
        child: SizedBox.square(dimension: 16, child: TweenAnimationBuilder<double>(
          tween: Tween(begin: percent ?? 0, end: percent ?? 0),
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          builder: (context, value, _) => CustomPaint(size: const Size.square(16), painter: _ContextUsagePainter(percent == null ? null : value)),
        )),
      ))),
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
