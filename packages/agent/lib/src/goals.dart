import 'package:protocol/protocol.dart';

/// The domain owns serialization and state transitions. Persistence is just the
/// agent's existing generic event/metadata API, with no tool-aware storage calls.
class GoalRuntime {
  GoalRuntime({required this.taskId, required this.tokens, required this.load, required this.save});
  final String taskId;
  final int Function() tokens;
  final Future<Json> Function(CancellationToken) load;
  final Future<void> Function(Json, CancellationToken) save;
  Json? _state;
  Future<void> _pending = Future.value();
  bool get active => _state?['goal']?['status'] == 'active';

  Future<Json> call(String method, Json arguments, {required CancellationToken cancellation}) {
    final operation = _pending.then((_) async {
      cancellation.throwIfCancelled();
      _state ??= await load(cancellation);
      final result = _goalOperation(_state!, taskId, tokens(), method, arguments);
      if (result.changed) {
        try {
          await save(result.state, cancellation);
          _state = result.state;
        } catch (_) { _state = null; rethrow; }
      }
      return result.output;
    });
    _pending = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}

({Json output, Json state, bool changed}) _goalOperation(Json state, String taskId, int tokens, String method, Json arguments) {
  final saved = state['goal'];
  Json? goal = saved == null ? null : jsonObject(saved);
  final now = DateTime.now().toUtc().microsecondsSinceEpoch;
  var checkpoint = state['clock'] as int?;
  var remainder = state['timeRemainder'] as int? ?? 0;
  var accounted = state['accountedTokens'] as int? ?? tokens;
  var changed = false;
  void account() {
    if (goal?['status'] != 'active') return;
    final delta = (tokens - accounted).clamp(0, 0x7fffffffffffffff);
    accounted = tokens;
    final micros = remainder + (checkpoint == null ? 0 : (now - checkpoint!).clamp(0, 0x7fffffffffffffff));
    final seconds = micros ~/ 1000000;
    remainder = micros % 1000000;
    goal = {...goal!, 'tokensUsed': (goal!['tokensUsed'] as int) + delta,
      'timeUsedSeconds': (goal!['timeUsedSeconds'] as int) + seconds};
    if (checkpoint != null) checkpoint = now;
    final budget = goal!['tokenBudget'] as int?;
    if (budget != null && (goal!['tokensUsed'] as int) >= budget) {
      goal!['status'] = 'budget_limited'; checkpoint = null;
    }
    changed = delta != 0 || seconds != 0 || goal!['status'] != 'active';
  }
  switch (method) {
    case 'get_goal': break;
    case 'begin':
      if (goal?['status'] == 'active') { checkpoint = now; account(); changed = true; }
    case 'end':
      account();
      if (checkpoint != null) { checkpoint = null; changed = true; }
    case 'account':
      account();
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
      goal = {'threadId': taskId, 'objective': objective, 'status': 'active', 'tokenBudget': ?budget,
        'tokensUsed': 0, 'timeUsedSeconds': 0, 'createdAt': now ~/ 1000000, 'updatedAt': now ~/ 1000000};
      checkpoint = now;
      remainder = 0;
      accounted = tokens;
      changed = true;
    case 'update_goal':
      if (goal == null) throw StateError('cannot update goal because this thread has no goal');
      final status = arguments['status'];
      if (!{'complete', 'blocked', 'paused'}.contains(status)) {
        throw const FormatException("update_goal can only mark the existing goal complete, blocked, or paused at the user's explicit request; resume, budget-limited, and usage-limited status changes are controlled by the user or system");
      }
      account();
      if (goal!['status'] != 'budget_limited' || status == 'complete') goal!['status'] = status;
      checkpoint = null;
      changed = true;
    default: throw StateError('Unknown goal operation: $method');
  }
  if (changed) {
    goal = {...goal!, 'updatedAt': now ~/ 1000000};
  }
  final budget = goal?['tokenBudget'] as int?;
  final complete = method == 'update_goal' && goal?['status'] == 'complete';
  final output = <String, dynamic>{
    'goal': goal,
    'remainingTokens': budget == null ? null : (budget - (goal!['tokensUsed'] as int)).clamp(0, budget),
    'completionBudgetReport': complete && (budget != null || (goal!['timeUsedSeconds'] as int) > 0)
      ? "Goal achieved. Report final usage from this tool result's structured goal fields. If `goal.tokenBudget` is present, include token usage from `goal.tokensUsed` and `goal.tokenBudget`. If `goal.timeUsedSeconds` is greater than 0, summarize elapsed time in a concise, human-friendly form appropriate to the response language." : null,
  };
  return (output: output, state: {'goal': goal, 'clock': checkpoint, 'timeRemainder': remainder, 'accountedTokens': accounted}, changed: changed);
}
