part of '../storage.dart';

/// Codex state/runtime/goals.rs, using the owning thread's connection rather
/// than a second goals database. All read/modify/write operations are atomic.
extension ThreadGoals on TaskStore {
  Json? _getGoal() {
    final row = db.select('SELECT * FROM thread_goals WHERE thread_id IS ?', [taskId]).firstOrNull;
    return row == null ? null : {
      'threadId': taskId, 'goalId': row['goal_id'], 'objective': row['objective'], 'status': row['status'],
      'tokenBudget': row['token_budget'], 'tokensUsed': row['tokens_used'], 'timeUsedSeconds': row['time_used_seconds'],
      'createdAtMs': row['created_at_ms'], 'updatedAtMs': row['updated_at_ms'],
    };
  }

  Object? goal(String method, Json params) {
    if (method == 'get') return _getGoal();
    if (method == 'hasDeferral') return db.select('SELECT 1 FROM thread_goal_continuation_deferrals WHERE thread_id IS ?', [taskId]).isNotEmpty;
    final ownsTransaction = db.raw.autocommit;
    db.execute(ownsTransaction ? 'BEGIN' : 'SAVEPOINT goal_write');
    var changed = false;
    try {
      final previous = _getGoal();
      Json? next = previous;
      Object? result;
      final now = DateTime.now().millisecondsSinceEpoch;
      switch (method) {
        case 'clearDeferral':
          db.execute('DELETE FROM thread_goal_continuation_deferrals WHERE thread_id IS ?', [taskId]);
        case 'snapshot':
          next = {...jsonObject(params['goal']), 'threadId': taskId};
          changed = true;
        case 'replace':
        case 'insert':
          if (method == 'insert' && previous != null && previous['status'] != 'complete') break;
          final budget = params['tokenBudget'] as int?;
          final status = params['status'] as String? ?? 'active';
          next = {'threadId': taskId, 'goalId': newUuidV7(), 'objective': requiredString(params, 'objective'),
            'status': status == 'active' && budget != null && budget <= 0 ? 'budget_limited' : status,
            'tokenBudget': budget, 'tokensUsed': 0, 'timeUsedSeconds': 0, 'createdAtMs': now, 'updatedAtMs': now};
          changed = true;
        case 'update':
          if (previous == null || params['expectedGoalId'] != null && params['expectedGoalId'] != previous['goalId']) break;
          next = {...previous,
            if (params['objective'] != null) 'objective': requiredString(params, 'objective'),
            if (params['status'] != null) 'status': requiredString(params, 'status'),
            if (params.containsKey('tokenBudget')) 'tokenBudget': params['tokenBudget'] as int?,
          };
          final budget = next['tokenBudget'] as int?;
          if (previous['status'] == 'budget_limited' && {'paused', 'blocked'}.contains(next['status'])) {
            next['status'] = 'budget_limited';
          } else if (next['status'] == 'active' && budget != null && (next['tokensUsed'] as int) >= budget) {
            next['status'] = 'budget_limited';
          }
          changed = params['objective'] != null || params['status'] != null || params.containsKey('tokenBudget');
          if (!changed) result = previous;
        case 'pause':
        case 'usageLimit':
          if (previous == null || previous['status'] != 'active' && !(method == 'usageLimit' && previous['status'] == 'budget_limited')) break;
          next = {...previous, 'status': method == 'pause' ? 'paused' : 'usage_limited'};
          changed = true;
        case 'account':
          final tokens = (params['tokenDelta'] as int? ?? 0).clamp(0, 0x7fffffffffffffff);
          final seconds = (params['timeDeltaSeconds'] as int? ?? 0).clamp(0, 0x7fffffffffffffff);
          final mode = params['mode'] as String? ?? 'activeOnly';
          final statuses = switch (mode) {
            'activeStatusOnly' => const {'active'},
            'activeOnly' => const {'active', 'budget_limited'},
            'activeOrComplete' => const {'active', 'budget_limited', 'complete'},
            'activeOrStopped' => const {'active', 'paused', 'blocked', 'usage_limited', 'budget_limited'},
            _ => throw const FormatException('Unknown goal accounting mode'),
          };
          if (previous != null && (tokens != 0 || seconds != 0) && statuses.contains(previous['status']) &&
              (params['expectedGoalId'] == null || params['expectedGoalId'] == previous['goalId'])) {
            next = {...previous, 'tokensUsed': (previous['tokensUsed'] as int) + tokens,
              'timeUsedSeconds': (previous['timeUsedSeconds'] as int) + seconds};
            final budget = next['tokenBudget'] as int?;
            if ((mode == 'activeOrStopped' || previous['status'] == 'active') && budget != null && (next['tokensUsed'] as int) >= budget) {
              next['status'] = 'budget_limited';
            }
            changed = true;
          }
          result = {'updated': changed, 'goal': next};
        case 'delete':
          db.execute('DELETE FROM thread_goals WHERE thread_id IS ?', [taskId]);
          result = previous;
        default: throw StateError('Unknown goal operation: $method');
      }
      if (changed) {
        next = {...next!, if (method != 'snapshot') 'updatedAtMs': now};
        db.execute('''INSERT INTO thread_goals VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(thread_id) DO UPDATE SET
          goal_id=excluded.goal_id,objective=excluded.objective,status=excluded.status,token_budget=excluded.token_budget,
          tokens_used=excluded.tokens_used,time_used_seconds=excluded.time_used_seconds,
          created_at_ms=excluded.created_at_ms,updated_at_ms=excluded.updated_at_ms''',
          [taskId, next['goalId'], next['objective'], next['status'], next['tokenBudget'], next['tokensUsed'],
            next['timeUsedSeconds'], next['createdAtMs'], next['updatedAtMs']]);
        if (method == 'snapshot') db.execute('INSERT OR IGNORE INTO thread_goal_continuation_deferrals VALUES (?)', [taskId]);
        if ((method == 'replace' || method == 'insert' || params['objective'] != null) &&
            (metadata('goal_preview') as String? ?? '').isEmpty) _metadata({'goal_preview': next['objective']});
        native.record([{'type': 'event_msg', 'payload': {'type': 'thread_goal_updated', 'threadId': taskId,
          'goal': protocolThreadGoal(next)}}]);
        result = method == 'account' ? {'updated': true, 'goal': next} : next;
        native.tryProject();
      }
      db.execute(ownsTransaction ? 'COMMIT' : 'RELEASE goal_write');
      return result;
    } catch (_) {
      db.execute(ownsTransaction ? 'ROLLBACK' : 'ROLLBACK TO goal_write');
      if (!ownsTransaction) db.execute('RELEASE goal_write');
      rethrow;
    }
  }
}
