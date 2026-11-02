part of '../storage.dart';

/// All goal mutations run in the existing serial SQLite owner and commit their
/// audit event with state; concurrent creates cannot replace an unfinished goal.
Json _goalOperation(TaskStore store, String method, Json arguments) {
  final saved = store.metadata('goal');
  Json? goal = saved == null ? null : jsonObject(saved);
  final now = DateTime.now().toUtc().microsecondsSinceEpoch;
  var checkpoint = store.metadata('goal_clock') as int?;
  var remainder = store.metadata('goal_time_remainder') as int? ?? 0;
  var changed = false;
  void account(int tokens) {
    if (goal?['status'] != 'active') return;
    final micros = remainder + (checkpoint == null ? 0 : (now - checkpoint!).clamp(0, 0x7fffffffffffffff));
    final seconds = micros ~/ 1000000;
    remainder = micros % 1000000;
    goal = {...goal!, 'tokensUsed': (goal!['tokensUsed'] as int) + tokens,
      'timeUsedSeconds': (goal!['timeUsedSeconds'] as int) + seconds};
    if (checkpoint != null) checkpoint = now;
    final budget = goal!['tokenBudget'] as int?;
    if (budget != null && (goal!['tokensUsed'] as int) >= budget) {
      goal!['status'] = 'budget_limited'; checkpoint = null;
    }
    changed = tokens != 0 || seconds != 0 || goal!['status'] != 'active';
  }
  switch (method) {
    case 'get_goal': break;
    case 'begin':
      if (goal?['status'] == 'active') { checkpoint = now; changed = true; }
    case 'end':
      account(0);
      if (checkpoint != null) { checkpoint = null; changed = true; }
    case 'account':
      final tokens = arguments['tokens'];
      if (tokens is! int || tokens < 0) throw const FormatException('Invalid goal token usage');
      account(tokens);
    case 'create_goal':
      if (goal != null && goal!['status'] != 'complete') {
        throw StateError('cannot create a new goal because this thread has an unfinished goal; complete the existing goal first');
      }
      final objective = requiredString(arguments, 'objective').trim();
      if (objective.isEmpty) throw const FormatException('goal objective must not be empty');
      if (objective.runes.length > 4000) throw const FormatException('goal objective must be at most 4000 characters');
      final budget = arguments['token_budget'];
      if (budget != null && (budget is! int || budget <= 0 || budget > 0x7fffffffffffffff)) {
        throw const FormatException('goal budgets must be positive when provided');
      }
      goal = {'threadId': store.taskId, 'objective': objective, 'status': 'active', 'tokenBudget': ?budget,
        'tokensUsed': 0, 'timeUsedSeconds': 0, 'createdAt': now ~/ 1000000, 'updatedAt': now ~/ 1000000};
      checkpoint = now;
      remainder = 0;
      changed = true;
    case 'update_goal':
      if (goal == null) throw StateError('cannot update goal because this thread has no goal');
      final status = arguments['status'];
      if (!{'complete', 'blocked', 'paused'}.contains(status)) {
        throw const FormatException("update_goal can only mark the existing goal complete, blocked, or paused at the user's explicit request; resume, budget-limited, and usage-limited status changes are controlled by the user or system");
      }
      account(0);
      if (goal!['status'] != 'budget_limited' || status == 'complete') goal!['status'] = status;
      checkpoint = null;
      changed = true;
    default: throw StateError('Unknown goal operation: $method');
  }
  if (changed) {
    goal = {...goal!, 'updatedAt': now ~/ 1000000};
    store.append('goal.updated', {'goal': goal}, metadata: {'goal': goal, 'goal_clock': checkpoint, 'goal_time_remainder': remainder});
  }
  final budget = goal?['tokenBudget'] as int?;
  final complete = method == 'update_goal' && goal?['status'] == 'complete';
  return {
    'goal': goal,
    'remainingTokens': budget == null ? null : (budget - (goal!['tokensUsed'] as int)).clamp(0, budget),
    'completionBudgetReport': complete && (budget != null || (goal!['timeUsedSeconds'] as int) > 0)
      ? "Goal achieved. Report final usage from this tool result's structured goal fields. If `goal.tokenBudget` is present, include token usage from `goal.tokensUsed` and `goal.tokenBudget`. If `goal.timeUsedSeconds` is greater than 0, summarize elapsed time in a concise, human-friendly form appropriate to the response language." : null,
  };
}
