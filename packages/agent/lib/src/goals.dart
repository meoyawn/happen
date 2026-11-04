import 'package:protocol/protocol.dart';

import 'goal_accounting.dart';
import 'goal_context.dart';

/// Host-owned goal extension. The inference isolate reports lifecycle events;
/// model tools, external mutations and continuation admission share this queue.
/// The sole session writer, not a KV copy, is authoritative for goal state.
class GoalRuntime {
  GoalRuntime({required this.threadId, required this.store, required this.notify, required this.inject,
    this.maxTokenBudget, this.persistent = true, this.rootAccounting, this.admitContinuation});
  final String threadId;
  final Future<Object?> Function(String, Json, CancellationToken) store;
  final void Function(Json) notify;
  final Future<void> Function(Json, CancellationToken) inject;
  final int? maxTokenBudget;
  final bool persistent;
  final GoalAccountingState? rootAccounting;
  final bool Function(Json)? admitContinuation;
  final accounting = GoalAccountingState();
  Future<void> _pending = Future.value();

  Future<Json> call(String method, Json args, {required CancellationToken cancellation}) {
    final operation = _pending.then((_) async {
      cancellation.throwIfCancelled();
      return await _call(method, args, cancellation);
    });
    _pending = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<Json?> _get(CancellationToken token) async {
    final result = await store('goal.get', {}, token);
    return result == null ? null : jsonObject(result);
  }

  void _updated(Json goal) => notify({'type': 'goal.updated', 'data': {'goal': protocolThreadGoal(goal)}});

  Future<Json?> _account(CancellationToken token, {String mode = 'activeOnly', bool keepBudgetActive = true}) async {
    final id = accounting.currentTurnId ?? accounting.interruptedTurnId;
    final snapshot = accounting.progressSnapshot(id);
    if (snapshot == null) return null;
    final result = jsonObject(await store('goal.account', {...snapshot, 'mode': mode}, token));
    if (result['updated'] != true) return null;
    final goal = jsonObject(result['goal']);
    accounting.markProgressAccounted(snapshot, goal['status'] as String, turnId: id, keepBudgetActive: keepBudgetActive);
    _updated(goal); return goal;
  }

  Future<void> _inject(Json item, CancellationToken token) async {
    final record = jsonObject(await store('append', {'type': 'context.injected', 'data': {'item': item}}, token));
    await inject(record, token);
  }

  Future<Json> _call(String method, Json args, CancellationToken token) async {
    if (const {'get_goal', 'create_goal', 'update_goal'}.contains(method) && !persistent) {
      throw StateError('Goal tools require a persistent thread.');
    }
    switch (method) {
      case 'begin':
        await store('goal.clearDeferral', {}, token);
        final id = requiredString(args, 'turnId');
        accounting.startTurn(id, jsonObject(args['usage'] ?? {}), plan: args['plan'] == true);
        if (args['automatic'] == true) accounting.markGoalContinuation(id);
        if (args['plan'] == true) { accounting.clearActiveGoal(); return {}; }
        final goal = await _get(token);
        if (goal != null && {'active', 'budget_limited'}.contains(goal['status'])) accounting.markTurnGoalActive(id, goal['goalId'] as String);
        return {};
      case 'usage':
        final usage = jsonObject(args['usage']);
        accounting.recordTokenUsage(requiredString(args, 'turnId'), usage);
        if (args['lastUsage'] case final Map<String, Object?> last) rootAccounting?.recordDescendantUsage(last);
        return {};
      case 'item':
        accounting.recordItem(requiredString(args, 'turnId'), jsonObject(args['item'])); return {};
      case 'toolFinished':
        accounting.recordToolOutcome(requiredString(args, 'turnId'), requiredString(args, 'name'), requiredString(args, 'outcome'));
        if (!{'success', 'unsuccessful', 'executionFailed'}.contains(args['outcome']) || args['name'] == 'update_goal') return {};
        final goal = await _account(token);
        if (goal?['status'] == 'budget_limited' && accounting.markBudgetReported(goal!['goalId'] as String)) {
          await _inject(goalSteering(goal, 'budget_limit'), token);
        }
        return {};
      case 'prepare':
      case 'account':
        await _account(token, keepBudgetActive: method != 'prepare'); return {};
      case 'get_goal': return goalToolResponse(await _get(token));
      case 'create_goal':
        final objective = validateGoalObjective(requiredString(args, 'objective'));
        final budget = validateGoalBudget(args['token_budget'] ?? maxTokenBudget, maxTokenBudget);
        final inserted = await store('goal.insert', {'objective': objective, 'tokenBudget': budget}, token);
        if (inserted == null) throw StateError('cannot create a new goal because this thread has an unfinished goal; complete the existing goal first');
        final goal = jsonObject(inserted);
        accounting.markCurrentTurnGoalActive(goal['goalId'] as String); _updated(goal);
        return goalToolResponse(goal);
      case 'update_goal':
        final status = args['status'];
        if (!{'complete', 'blocked', 'paused'}.contains(status)) throw const FormatException(
          "update_goal can only mark the existing goal complete, blocked, or paused at the user's explicit request; resume, budget-limited, and usage-limited status changes are controlled by the user or system");
        await _account(token, mode: status == 'complete' ? 'activeOrComplete' : 'activeOrStopped', keepBudgetActive: false);
        final updated = await store('goal.update', {'status': status}, token);
        if (updated == null) throw StateError('cannot update goal because this thread has no goal');
        final goal = jsonObject(updated); accounting.clearActiveGoal(); _updated(goal);
        return goalToolResponse(goal, completion: status == 'complete');
      case 'set':
        final objective = args['objective'] == null ? null : validateGoalObjective(requiredString(args, 'objective'));
        final status = args['status'] == null ? null : goalStateStatus(requiredString(args, 'status'));
        final budget = args.containsKey('tokenBudget') ? validateGoalBudget(args['tokenBudget'] ?? maxTokenBudget, maxTokenBudget) : null;
        await _account(token, keepBudgetActive: false);
        final existing = await _get(token);
        if (existing == null && objective == null) throw StateError('cannot update goal for thread $threadId: no goal exists');
        if (args['origin'] == 'user' && (objective != null || status != null)) {
          await _inject(userGoalInstruction(objective: objective, status: status), token);
        }
        final goal = jsonObject(await store(existing == null ? 'goal.replace' : 'goal.update', {
          'objective': ?objective, 'status': ?status,
          if (args.containsKey('tokenBudget') || existing == null) 'tokenBudget': budget ?? (existing == null ? maxTokenBudget : null),
          if (existing != null) 'expectedGoalId': existing['goalId'],
        }, token));
        if (goal['status'] == 'active') {
          accounting.markCurrentTurnGoalActive(goal['goalId'] as String);
          if (existing?['status'] == 'active' && existing?['objective'] != goal['objective'] && accounting.currentTurnId != null) {
            await _inject(goalSteering(goal, 'objective_updated'), token);
          }
        } else { accounting.clearActiveGoal(); }
        if (args['deferNotification'] != true) _updated(goal);
        return {'goal': protocolThreadGoal(goal)};
      case 'clear':
        await _account(token, keepBudgetActive: false);
        if (args['origin'] == 'user') await _inject(userGoalInstruction(clear: true), token);
        final deleted = await store('goal.delete', {}, token);
        accounting.clearActiveGoal();
        if (deleted != null && args['deferNotification'] != true) notify({'type': 'goal.cleared', 'data': <String, Object?>{}});
        return {'cleared': deleted != null};
      case 'end':
        final id = requiredString(args, 'turnId');
        if ((accounting.currentTurnId ?? accounting.interruptedTurnId) != id) return {};
        final activeId = accounting.activeGoalForTurn(id);
        final reason = args['reason'] as String?;
        final stop = activeId != null && (reason == 'error' || reason == 'usageLimit' ||
          accounting.executionFailureGoal(id) != null || accounting.emptyResponseGoal(id) != null);
        await _account(token, keepBudgetActive: false);
        if (stop) {
          final goal = await _get(token);
          if (goal != null && goal['goalId'] == activeId && (goal['status'] == 'active' || reason == 'usageLimit' && goal['status'] == 'budget_limited')) {
            final stopped = jsonObject(await store('goal.update', {'status': reason == 'usageLimit' ? 'usage_limited' : 'blocked', 'expectedGoalId': activeId}, token));
            _updated(stopped);
          }
          accounting.clearActiveGoal();
        }
        accounting.finishTurn(id); return {};
      case 'resume':
        final goal = await _get(token);
        if (goal?['status'] == 'active') { accounting.markIdleGoalActive(goal!['goalId'] as String); }
        else { accounting.clearActiveGoal(); }
        return {};
      case 'continuation':
        if (!persistent || await store('goal.hasDeferral', {}, token) == true) return {};
        final goal = await _get(token);
        if (goal?['status'] != 'active') { accounting.clearActiveGoal(); return {}; }
        final item = goalSteering(goal!, 'continuation');
        if (admitContinuation?.call(item) == false) { accounting.resetIdleProgress(); return {}; }
        return {'item': item};
      default: throw StateError('Unknown goal operation: $method');
    }
  }
}

String validateGoalObjective(String objective) {
  final trimmed = objective.trim();
  if (trimmed.isEmpty) throw const FormatException('goal objective must not be empty');
  if (trimmed.runes.length > 4000) throw const FormatException('goal objective must be at most 4000 characters');
  return trimmed;
}

int? validateGoalBudget(Object? value, int? maximum) {
  if (value == null) return null;
  if (value is! int || value <= 0) throw const FormatException('goal budgets must be positive when provided');
  if (maximum != null && value > maximum) throw FormatException('goal token budget $value exceeds the maximum allowed goal token budget of $maximum');
  return value;
}

String goalStateStatus(String value) => switch (value) {
  'usageLimited' => 'usage_limited', 'budgetLimited' => 'budget_limited',
  'active' || 'paused' || 'blocked' || 'complete' => value,
  _ => throw const FormatException('Invalid goal status'),
};

Json goalToolResponse(Json? goal, {bool completion = false}) => {
  'goal': goal == null ? null : protocolThreadGoal(goal),
  'remainingTokens': goal?['tokenBudget'] == null ? null : ((goal!['tokenBudget'] as int) - (goal['tokensUsed'] as int)).clamp(0, 0x7fffffffffffffff),
  'completionBudgetReport': completion && goal?['status'] == 'complete' && (goal?['tokenBudget'] != null || (goal!['timeUsedSeconds'] as int) > 0)
    ? "Goal achieved. Report final usage from this tool result's structured goal fields. If `goal.tokenBudget` is present, include token usage from `goal.tokensUsed` and `goal.tokenBudget`. If `goal.timeUsedSeconds` is greater than 0, summarize elapsed time in a concise, human-friendly form appropriate to the response language." : null,
};
// Dart port of Codex ext/goal/{api,runtime,tool,extension}.rs. See docs/codex-port.md.
