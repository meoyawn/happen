import 'dart:async';
import 'package:flutter/material.dart';
import 'package:protocol/protocol.dart';

import 'appearance.dart';
import 'goal_state.dart';

class GoalModeButton extends StatelessWidget {
  const GoalModeButton({super.key, required this.onClear});
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => Tooltip(message: 'Exit goal mode', child: TextButton.icon(
    onPressed: onClear,
    style: TextButton.styleFrom(foregroundColor: desktopForeground,
      backgroundColor: const Color(0xfff0f0f2), minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
    icon: const Icon(Icons.track_changes_rounded, size: 15),
    label: const Row(mainAxisSize: MainAxisSize.min, children: [
      Text('Goal', style: TextStyle(fontSize: 12)), SizedBox(width: 6),
      Icon(Icons.close_rounded, size: 13),
    ]),
  ));
}

/// A saved goal stays visible between turns; only turn activity means Thinking.
class GoalStatusRail extends StatelessWidget {
  const GoalStatusRail({super.key, required this.goal, required this.write,
    required this.enabled, required this.onStatus, required this.onClear,
    required this.onEdit, required this.onRetry});
  final Json? goal;
  final GoalWriteState write;
  final bool enabled;
  final ValueChanged<String> onStatus;
  final VoidCallback onClear, onEdit, onRetry;

  @override
  Widget build(BuildContext context) {
    final failed = write is GoalWriteFailed;
    final pending = write is GoalWritePending;
    final mutation = switch (write) {
      GoalWritePending(:final mutation) => mutation,
      GoalWriteFailed(:final write) => write.mutation,
      _ => null,
    };
    final status = goal?['status'];
    final label = failed ? mutation?.clear == true ? 'Could not clear goal' : 'Goal not saved'
      : goal == null && pending ? 'Saving goal…' : switch (status) {
      'active' => 'Pursuing goal', 'paused' => 'Paused goal', 'blocked' => 'Goal stalled',
      'usageLimited' => 'Goal usage limited', 'budgetLimited' => 'Goal limited',
      'complete' => 'Goal achieved', _ => 'Goal',
    };
    final nextStatus = switch (status) {
      'active' => 'paused', 'paused' || 'blocked' || 'usageLimited' => 'active', _ => null,
    };
    final available = enabled && !pending;
    final objective = goal?['objective'] as String? ?? mutation?.objective ?? '';
    return Container(
      key: const ValueKey('goal-status'),
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
      decoration: const BoxDecoration(color: Color(0xfff6f6f7),
        border: Border(top: BorderSide(color: desktopBorder), left: BorderSide(color: desktopBorder),
          right: BorderSide(color: desktopBorder)),
        borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      child: Row(children: [
        if (pending) const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 1.5))
        else Icon(status == 'complete' ? Icons.check_circle_outline_rounded : Icons.track_changes_rounded,
          size: 16, color: desktopSecondary),
        const SizedBox(width: 8),
        Expanded(child: Tooltip(message: failed ? (write as GoalWriteFailed).error.toString() : objective,
          child: InkWell(onTap: available ? onEdit : null, borderRadius: BorderRadius.circular(4),
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text.rich(
              TextSpan(text: label, style: const TextStyle(fontSize: 12, color: desktopForeground),
                children: [TextSpan(text: '  $objective', style: const TextStyle(color: desktopSecondary))]),
              maxLines: 1, overflow: TextOverflow.ellipsis))))),
        if (goal != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 6),
          child: _GoalProgress(goal: goal!)),
        if (failed) _action('Retry saving goal', Icons.refresh_rounded, available ? onRetry : null)
        else if (nextStatus != null) _action(nextStatus == 'paused' ? 'Pause goal' : 'Resume goal',
          nextStatus == 'paused' ? Icons.pause_rounded : Icons.play_arrow_rounded,
          available ? () => onStatus(nextStatus) : null),
        if (goal != null) ...[
          _action('Edit goal', Icons.edit_outlined, available ? onEdit : null),
          _action('Clear goal', Icons.close_rounded, available ? onClear : null),
        ],
      ]),
    );
  }

  Widget _action(String label, IconData icon, VoidCallback? action) => IconButton(
    tooltip: label, onPressed: action, icon: Icon(icon, size: 15),
    style: IconButton.styleFrom(foregroundColor: desktopSecondary, padding: EdgeInsets.zero,
      minimumSize: const Size.square(26), maximumSize: const Size.square(26)));
}

class _GoalProgress extends StatefulWidget {
  const _GoalProgress({required this.goal});
  final Json goal;
  @override
  State<_GoalProgress> createState() => _GoalProgressState();
}

class _GoalProgressState extends State<_GoalProgress> {
  Timer? _timer;

  void _sync() {
    _timer?.cancel();
    if (widget.goal['status'] == 'active' && widget.goal['tokenBudget'] == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
    }
  }

  @override
  void initState() { super.initState(); _sync(); }
  @override
  void didUpdateWidget(_GoalProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.goal['status'] != widget.goal['status'] || oldWidget.goal['tokenBudget'] != widget.goal['tokenBudget']) _sync();
  }
  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final goal = widget.goal, budget = goal['tokenBudget'] as num?;
    String compact(num value) => value < 1000 ? '$value' : value < 1000000
      ? '${(value / 1000).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')}k'
      : '${(value / 1000000).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')}m';
    final used = goal['timeUsedSeconds'] as num? ?? 0;
    final extra = goal['status'] == 'active' && goal['updatedAt'] is num
      ? DateTime.now().millisecondsSinceEpoch ~/ 1000 - (goal['updatedAt'] as num).toInt() : 0;
    final seconds = (used.toInt() + extra).clamp(0, 0x7fffffff);
    final elapsed = seconds >= 3600 ? '${seconds ~/ 3600}h ${seconds ~/ 60 % 60}m'
      : seconds >= 60 ? '${seconds ~/ 60}m ${seconds % 60}s' : '${seconds}s';
    final tokens = budget != null && {'active', 'budgetLimited'}.contains(goal['status']);
    return Tooltip(message: '${goal['tokensUsed'] ?? 0} tokens used · $elapsed',
      child: Text(tokens ? '${compact(goal['tokensUsed'] as num? ?? 0)} / ${compact(budget)}' : elapsed,
        style: const TextStyle(fontSize: 11, color: desktopSecondary, fontFeatures: [FontFeature.tabularFigures()])));
  }
}
