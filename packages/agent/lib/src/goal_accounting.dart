import 'package:protocol/protocol.dart';

/// Codex ext/goal/src/accounting.rs. Thread-local state is owned by the host,
/// not an inference isolate, so counters and descendant usage survive turns.
class GoalAccountingState {
  final _turns = <String, Json>{};
  final _clock = Stopwatch()..start();
  String? currentTurnId, interruptedTurnId;
  String? _wallGoalId, _reportedBudgetId, _failureGoalId, _automaticTurnId;
  int _wallBaseline = 0, _descendantTokens = 0, _accountedDescendants = 0;
  int _failureTurns = 0, _emptyTurns = 0;

  void startTurn(String id, Json usage, {bool plan = false}) {
    if (interruptedTurnId case final interrupted?) { _turns.remove(interrupted); _emptyTurns = 0; }
    interruptedTurnId = null; currentTurnId = id;
    _turns[id] = {'usage': {...usage}, 'baseline': {...usage}, 'accountTokens': !plan,
      'goalId': null, 'failedExecution': false, 'successfulTool': false, 'emptyFinal': false, 'activity': false};
  }

  String? activeGoalForTurn(String id) => (currentTurnId ?? interruptedTurnId) == id && _turns[id]?['accountTokens'] == true
    ? (_turns[id]?['goalId'] as String?) : null;

  Json? recordTokenUsage(String id, Json usage) {
    final turn = _turns[id];
    if (turn == null) return null;
    turn['usage'] = {...usage};
    if (turn['accountTokens'] != true) return null;
    final delta = _tokenDelta(jsonObject(turn['baseline']), usage);
    if (delta <= 0) return null;
    return {'turnDelta': delta, 'threadUnflushedDelta': _turns.values.where((turn) => turn['accountTokens'] == true)
      .fold<int>(0, (sum, turn) => sum + _tokenDelta(jsonObject(turn['baseline']), jsonObject(turn['usage'])).clamp(0, 0x7fffffffffffffff))};
  }

  void recordDescendantUsage(Json usage) { _descendantTokens += _tokenDelta({}, usage).clamp(0, 0x7fffffffffffffff); }

  void markTurnGoalActive(String id, String goalId) {
    if (!_turns.containsKey(id)) return;
    _turns[id]!['goalId'] = goalId;
    if (currentTurnId == id) markIdleGoalActive(goalId);
  }

  void markCurrentTurnGoalActive(String goalId) {
    final turn = _turns[currentTurnId];
    if (turn == null) { markIdleGoalActive(goalId); return; }
    if (turn['goalId'] != goalId) { turn['failedExecution'] = false; turn['successfulTool'] = false; }
    if (_wallGoalId != goalId) {
      turn['baseline'] = {...jsonObject(turn['usage'])}; _automaticTurnId = null;
    }
    turn['goalId'] = goalId; markIdleGoalActive(goalId);
  }

  void markIdleGoalActive(String goalId) {
    if (_reportedBudgetId != goalId) _reportedBudgetId = null;
    if (_wallGoalId != goalId) {
      _emptyTurns = 0; _accountedDescendants = _descendantTokens;
      _wallBaseline = _clock.elapsedMicroseconds; _wallGoalId = goalId;
    }
  }

  void clearActiveGoal() {
    _turns[currentTurnId]?['goalId'] = null;
    resetIdleProgress(); _failureGoalId = null; _failureTurns = 0; resetEmptyResponses();
  }

  void resetIdleProgress() {
    _wallBaseline = _clock.elapsedMicroseconds; _wallGoalId = null; _reportedBudgetId = null;
  }

  Json? progressSnapshot(String? id) {
    final turn = _turns[id];
    if (id != null && (turn == null || turn['accountTokens'] != true)) return null;
    final goalId = id == null ? _wallGoalId : turn!['goalId'] as String?;
    if (goalId == null) return null;
    final tokens = (turn == null ? 0 : _tokenDelta(jsonObject(turn['baseline']), jsonObject(turn['usage']))) + _descendantTokens - _accountedDescendants;
    final seconds = _wallGoalId == goalId ? (_clock.elapsedMicroseconds - _wallBaseline) ~/ 1000000 : 0;
    if (tokens <= 0 && seconds == 0) return null;
    return {'expectedGoalId': goalId, 'tokenDelta': tokens, 'timeDeltaSeconds': seconds,
      'usage': turn == null ? null : {...jsonObject(turn['usage'])}, 'descendantTokens': _descendantTokens};
  }

  void markProgressAccounted(Json snapshot, String status, {String? turnId, bool keepBudgetActive = true}) {
    final clear = status != 'active' && !(status == 'budget_limited' && keepBudgetActive);
    final turn = _turns[turnId];
    if (turn != null) {
      turn['baseline'] = snapshot['usage'];
      if (clear) turn['goalId'] = null;
    }
    _accountedDescendants = snapshot['descendantTokens'] as int;
    _wallBaseline += (snapshot['timeDeltaSeconds'] as int) * 1000000;
    if (clear) { _wallGoalId = null; _wallBaseline = _clock.elapsedMicroseconds; }
    if (status != 'budget_limited') _reportedBudgetId = null;
  }

  bool markBudgetReported(String goalId) {
    if (_reportedBudgetId == goalId) return false;
    _reportedBudgetId = goalId; return true;
  }

  void recordToolOutcome(String id, String name, String outcome) {
    _emptyTurns = 0;
    final turn = _turns[id];
    if (turn == null) return;
    turn['activity'] = true;
    if (turn['goalId'] == null) return;
    if (outcome == 'success') {
      turn['successfulTool'] = true; _failureGoalId = null; _failureTurns = 0;
    } else if (outcome == 'executionFailed' && {'exec', 'functions.exec'}.contains(name)) {
      turn['failedExecution'] = true;
    }
  }

  String? executionFailureGoal(String id) {
    final turn = _turns[id], goal = _turns[id]?['goalId'] as String?;
    if (goal == null || turn!['successfulTool'] == true || turn['failedExecution'] != true) return null;
    if (_failureGoalId != goal) { _failureGoalId = goal; _failureTurns = 0; }
    return ++_failureTurns >= 3 ? goal : null;
  }

  void recordItem(String id, Json item) {
    final turn = _turns[id];
    if (turn == null) return;
    var activity = false;
    if (item['type'] == 'agentMessage') {
      activity = (item['text'] as String? ?? '').trim().isNotEmpty || item['questions'] != null;
      if (!activity && {null, 'final_answer'}.contains(item['phase'])) turn['emptyFinal'] = true;
    } else if (item['type'] == 'reasoning') {
      activity = (item['summary'] as List? ?? []).any((text) => (text as String).trim().isNotEmpty);
    } else { activity = true; }
    if (activity) { turn['activity'] = true; _emptyTurns = 0; }
  }

  void markGoalContinuation(String id) { _automaticTurnId = id; }
  void resetEmptyResponses() { _automaticTurnId = null; _emptyTurns = 0; }
  String? emptyResponseGoal(String id) {
    final interrupted = interruptedTurnId == id;
    if (interrupted) interruptedTurnId = null;
    final turn = _turns[id], goalId = _turns[id]?['goalId'] as String?;
    if (turn == null || goalId == null) return null;
    final empty = _automaticTurnId == id && turn['activity'] != true && (turn['emptyFinal'] == true || interrupted);
    turn['emptyFinal'] = false;
    if (!empty) { _emptyTurns = 0; return null; }
    return ++_emptyTurns >= 3 ? goalId : null;
  }

  void interruptTurn(String id) {
    if (currentTurnId == id) { currentTurnId = null; interruptedTurnId = id; }
    else { _turns.remove(id); }
  }
  void finishTurn(String id) {
    _turns.remove(id);
    if (currentTurnId == id) currentTurnId = null;
    if (interruptedTurnId == id) interruptedTurnId = null;
  }
}

int _tokenDelta(Json before, Json after) =>
  ((after['input_tokens'] as int? ?? 0) - (before['input_tokens'] as int? ?? 0)) -
  ((after['cached_input_tokens'] as int? ?? 0) - (before['cached_input_tokens'] as int? ?? 0)) +
  ((after['output_tokens'] as int? ?? 0) - (before['output_tokens'] as int? ?? 0)).clamp(0, 0x7fffffffffffffff);
